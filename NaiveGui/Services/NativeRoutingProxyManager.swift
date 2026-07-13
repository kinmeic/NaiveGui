import Darwin
import Foundation
import Network
import zlib

enum RuleSetLoadStatus: Equatable {
    case ready
    case loading
    case failed
    case notLoaded
}

/// 默认超时配置。所有值的单位是秒/毫秒，按字段语义。
enum SocketTimeout {
    /// TCP connect 超时（毫秒）。对不可达主机，原来会卡 ~75s，现在 10s 内失败。
    static let connectMs: Int32 = 10_000
    /// readExact / readHeader 的接收超时（秒）。握手阶段读超过这个时间认为对端无响应。
    static let handshakeRecvSec: Int32 = 30
}

/// poll 包装：等待 fd 可读或可写，返回是否就绪（超时返回 false）。
private func waitForSocketReady(_ fd: Int32, events: Int16, timeoutMs: Int32) -> Bool {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    let n = poll(&pfd, 1, timeoutMs)
    return n > 0 && (pfd.revents & events) != 0
}

final class NativeRoutingProxyManager: @unchecked Sendable {
    static let shared = NativeRoutingProxyManager()
    static let ruleSetStatusDidChange = Notification.Name("NativeRoutingProxyManagerRuleSetStatusDidChange")
    static let builtInRuleSetTags = [
        "geoip-cn",
        "geosite-cn",
        "geosite-private",
        "geosite-apple@cn",
        "geosite-google@cn",
        "geosite-microsoft@cn",
        "geosite-category-games-cn",
        "geosite-openai",
        "geosite-anthropic",
        "geosite-github",
        "geosite-github-copilot",
        "geosite-google-gemini",
        "geosite-google",
        "geosite-youtube",
        "geosite-telegram",
        "geosite-geolocation-!cn"
    ]

    /// start/stop/UI 查询可来自不同线程；运行时对象统一经此锁保护容器访问。
    private struct RuntimeState {
        var socksServer: TCPServer?
        var httpServer: TCPServer?
        var router: NativeRouteMatcher?
        var isStarting = false
        var generation: UInt64 = 0
    }
    private let runtime = LockedBox(RuntimeState())
    private let appSupportURL: URL
    /// 当前活跃的客户端 socket 集合。stop 时主动关闭它们，让 relay 线程退出。
    private var activeSockets: Set<Int32> = []
    private var acceptingGeneration: UInt64?
    private let activeSocketsLock = NSLock()
    private let logCallback = LogLineCallback()
    private let exitCallback = EventCallback()

    var isRunning: Bool {
        runtime.withLock {
            $0.socksServer?.isRunning == true || $0.httpServer?.isRunning == true
        }
    }

    func installLogHandler(_ handler: LogLineCallback.Handler?) {
        logCallback.install(handler)
    }

    func installUnexpectedExitHandler(_ handler: EventCallback.Handler?) {
        exitCallback.install(handler)
    }

    func ruleSetStatuses(for tags: Set<String>) -> [String: RuleSetLoadStatus] {
        guard let router = runtime.withLock({ $0.router }) else {
            return Dictionary(uniqueKeysWithValues: tags.map { ($0, .notLoaded) })
        }
        return router.ruleSetStatuses(for: tags)
    }

    private init() {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appSupportURL = urls[0].appendingPathComponent("NaiveGui", isDirectory: true)
    }

    static func updateBuiltInRuleSets() throws {
        let cacheURL = ruleSetCacheDirectory()
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        // 并行下载所有规则集，比串行快很多（16 文件原本要依次等）。
        let group = DispatchGroup()
        let firstError = LockedBox<Error?>(nil)

        for tag in builtInRuleSetTags {
            guard let url = RuleSetStore.remoteURL(for: tag) else { continue }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try downloadWithTimeout(url: url, timeoutSec: 30)
                    try data.write(to: cacheURL.appendingPathComponent("\(tag).srs"), options: .atomic)
                } catch {
                    firstError.withLock {
                        if $0 == nil { $0 = error }
                    }
                }
                group.leave()
            }
        }
        group.wait()

        notifyRuleSetStatusDidChange()
        if let error = firstError.withLock({ $0 }) { throw error }
    }

    /// 用 URLSession 同步包装实现带超时的下载。Data(contentsOf:) 无法设超时，
    /// 慢/挂起的服务器会无限等待，这里限制单文件最多 timeoutSec 秒。
    /// 含 HTTP 状态码校验与超时安全访问（避免 force unwrap 崩溃）。
    private static func downloadWithTimeout(url: URL, timeoutSec: TimeInterval) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSec
        let semaphore = DispatchSemaphore(value: 0)
        // 用可空 result + 标志位，避免超时后访问隐式解包 nil 崩溃。
        let result = LockedBox<Result<Data, Error>?>(nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result.withLock { $0 = .failure(error) }
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result.withLock { $0 = .failure(URLError(.badServerResponse)) }
            } else {
                result.withLock { $0 = .success(data ?? Data()) }
            }
            semaphore.signal()
        }.resume()
        // 加保险超时，防止 URLSession 的 timeoutInterval 在某些情况下不生效。
        let waited = semaphore.wait(timeout: .now() + timeoutSec + 5)
        switch waited {
        case .success:
            // 回调已执行，result 必非 nil。
            return try result.withLock { try $0?.get() ?? Data() }
        case .timedOut:
            // 回调未到，result 可能为 nil，不能用 force unwrap。
            throw URLError(.timedOut)
        }
    }

    static func notifyRuleSetStatusDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ruleSetStatusDidChange, object: nil)
        }
    }

    private static func ruleSetCacheDirectory() -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls[0]
            .appendingPathComponent("NaiveGui", isDirectory: true)
            .appendingPathComponent("rule-set-cache", isDirectory: true)
    }

    func start(
        naivePort: Int,
        routingPort: Int,
        routingHTTPPort: Int,
        routingListenAddress: String,
        defaultOutbound: RuleAction,
        rules: [RoutingRule],
        maxConnections: Int
    ) throws {
        let generation = runtime.withLock { state -> UInt64? in
            let running = state.socksServer?.isRunning == true || state.httpServer?.isRunning == true
            guard !running, !state.isStarting else { return nil }
            state.isStarting = true
            state.generation &+= 1
            return state.generation
        }
        guard let generation else { return }
        var installed = false
        defer {
            if !installed {
                runtime.withLock { state in
                    if state.generation == generation {
                        state.isStarting = false
                    }
                }
            }
        }

        // 按当前配置重建连接限制器（用户可能在设置里改了上限）。
        let limiter = ConnectionLimiter(maxConnections: min(max(maxConnections, 1), 65535))

        let cacheURL = Self.ruleSetCacheDirectory()
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let routeMatcher = NativeRouteMatcher(
            defaultOutbound: defaultOutbound,
            rules: rules,
            ruleSetStore: RuleSetStore(cacheDirectory: cacheURL) { [weak self] line, isError in
                self?.logCallback.invoke(line, isStderr: isError)
            },
            logger: { [weak self] line, isError in
                self?.logCallback.invoke(line, isStderr: isError)
            }
        )

        let socks = try TCPServer(host: routingListenAddress, port: routingPort) { [weak self] socket in
            self?.handleSOCKS(
                socket: socket,
                naivePort: naivePort,
                router: routeMatcher,
                limiter: limiter,
                generation: generation
            )
        }
        let http = try TCPServer(host: routingListenAddress, port: routingHTTPPort) { [weak self] socket in
            self?.handleHTTP(
                socket: socket,
                naivePort: naivePort,
                router: routeMatcher,
                limiter: limiter,
                generation: generation
            )
        }

        installed = runtime.withLock { state in
            guard state.generation == generation, state.isStarting else { return false }
            state.socksServer = socks
            state.httpServer = http
            state.router = routeMatcher
            state.isStarting = false
            // 与安装状态处于同一临界区，避免 stop 夹在安装和 start 之间留下孤儿 listener。
            setAcceptingConnections(generation: generation)
            socks.start()
            http.start()
            return true
        }
        guard installed else {
            socks.stop()
            http.stop()
            return
        }
        logCallback.invoke("native routing SOCKS listening on \(routingListenAddress):\(routingPort)", isStderr: false)
        logCallback.invoke("native routing HTTP listening on \(routingListenAddress):\(routingHTTPPort)", isStderr: false)
        routeMatcher.preloadRuleSets()
    }

    func stop() {
        let servers = runtime.withLock { state -> (TCPServer?, TCPServer?) in
            state.generation &+= 1
            state.isStarting = false
            let servers = (state.socksServer, state.httpServer)
            state.socksServer = nil
            state.httpServer = nil
            state.router = nil
            return servers
        }
        servers.0?.stop()
        servers.1?.stop()
        // 主动关闭现有活跃连接，让 relay 线程退出（仅停监听 socket 不够）。
        closeAllActiveSockets()
        Self.notifyRuleSetStatusDidChange()
    }

    @discardableResult
    private func registerActiveSocket(_ fd: Int32, generation: UInt64) -> Bool {
        activeSocketsLock.lock()
        guard acceptingGeneration == generation else {
            activeSocketsLock.unlock()
            return false
        }
        activeSockets.insert(fd)
        activeSocketsLock.unlock()
        return true
    }

    private func unregisterActiveSocket(_ fd: Int32) {
        activeSocketsLock.lock()
        activeSockets.remove(fd)
        activeSocketsLock.unlock()
    }

    /// 关闭所有活跃 socket，触发 relay 完成。覆盖客户端 socket + 上游 socket。
    private func closeAllActiveSockets() {
        activeSocketsLock.lock()
        acceptingGeneration = nil
        let toClose = Array(activeSockets)
        activeSockets.removeAll()
        activeSocketsLock.unlock()
        for fd in toClose {
            // relay socket 交给 Hub 统一完成；仍处于握手阶段的 socket 直接 shutdown。
            if !RelayHub.shared.shutdownRelay(containing: fd) {
                _ = shutdown(fd, SHUT_RDWR)
            }
        }
    }

    private func setAcceptingConnections(generation: UInt64?) {
        activeSocketsLock.lock()
        acceptingGeneration = generation
        activeSocketsLock.unlock()
    }

    private func handleSOCKS(
        socket: Int32,
        naivePort: Int,
        router: NativeRouteMatcher,
        limiter: ConnectionLimiter,
        generation: UInt64
    ) {
        // 先捕获 limiter 实例，确保 acquire/release 配对到同一实例。
        // 避免 stop+start 期间旧连接 release 到新 limiter 导致计数错乱。
        guard registerActiveSocket(socket, generation: generation) else {
            close(socket)
            return
        }
        guard limiter.acquire() else {
            logCallback.invoke("SOCKS rejected: connection limit reached", isStderr: true)
            try? SOCKS5.writeReply(to: socket, status: 0x01)
            unregisterActiveSocket(socket)
            close(socket)
            return
        }
        var upstream: Int32 = -1
        var handedToRelay = false
        defer {
            if !handedToRelay {
                unregisterActiveSocket(socket)
                close(socket)
                if upstream >= 0 {
                    close(upstream)
                }
                limiter.release()
            }
        }
        // 握手阶段设接收超时，防止恶意/卡死客户端占用线程。
        SocketIO.setRecvTimeout(socket, seconds: SocketTimeout.handshakeRecvSec)
        do {
            let destination = try SOCKS5.readClientRequest(from: socket)
            logCallback.invoke("SOCKS \(destination.host):\(destination.port) accepted", isStderr: false)
            let decision = router.decision(for: destination)
            logCallback.invoke("SOCKS \(destination.host):\(destination.port) -> \(decision.logAction) (\(decision.reason))", isStderr: false)

            guard decision.action != .block else {
                try SOCKS5.writeReply(to: socket, status: 0x02)
                return
            }

            if decision.action == .proxy {
                upstream = try connectViaNaive(naivePort: naivePort, destination: destination)
            } else {
                // 直连：优先用 DoH 解析出的 IP（避免再次本地 DNS 查询）；无解析结果则用原 host（走系统 DNS）。
                let connectHost = decision.resolvedIP ?? destination.host
                upstream = try SocketIO.connect(host: connectHost, port: destination.port)
            }

            try SOCKS5.writeReply(to: socket, status: 0x00)
            handedToRelay = true
            relayTracked(
                socket: socket,
                upstream: upstream,
                host: destination.host,
                port: destination.port,
                decision: decision,
                limiter: limiter,
                generation: generation
            )
        } catch {
            guard !SocketError.isBenignDisconnect(error) else { return }
            logCallback.invoke("SOCKS error: \(error.localizedDescription)", isStderr: true)
            try? SOCKS5.writeReply(to: socket, status: 0x01)
        }
    }

    private func handleHTTP(
        socket: Int32,
        naivePort: Int,
        router: NativeRouteMatcher,
        limiter: ConnectionLimiter,
        generation: UInt64
    ) {
        // 先捕获 limiter 实例，确保 acquire/release 配对到同一实例。
        guard registerActiveSocket(socket, generation: generation) else {
            close(socket)
            return
        }
        guard limiter.acquire() else {
            logCallback.invoke("HTTP rejected: connection limit reached", isStderr: true)
            try? SocketIO.writeAll(socket, Data("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            unregisterActiveSocket(socket)
            close(socket)
            return
        }
        var upstream: Int32 = -1
        var handedToRelay = false
        defer {
            if !handedToRelay {
                unregisterActiveSocket(socket)
                close(socket)
                if upstream >= 0 {
                    close(upstream)
                }
                limiter.release()
            }
        }
        // 握手阶段设接收超时，防止恶意/卡死客户端占用线程。
        SocketIO.setRecvTimeout(socket, seconds: SocketTimeout.handshakeRecvSec)
        do {
            let request = try HTTPProxyRequest.read(from: socket)
            logCallback.invoke("HTTP \(request.destination.host):\(request.destination.port) accepted", isStderr: false)
            let decision = router.decision(for: request.destination)
            logCallback.invoke("HTTP \(request.destination.host):\(request.destination.port) -> \(decision.logAction) (\(decision.reason))", isStderr: false)

            guard decision.action != .block else {
                try SocketIO.writeAll(socket, Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                return
            }

            if decision.action == .proxy {
                upstream = try connectViaNaive(naivePort: naivePort, destination: request.destination)
            } else {
                // 直连：优先用 DoH 解析出的 IP（避免再次本地 DNS 查询）；无解析结果则用原 host。
                let connectHost = decision.resolvedIP ?? request.destination.host
                upstream = try SocketIO.connect(host: connectHost, port: request.destination.port)
            }

            if request.isConnect {
                try SocketIO.writeAll(socket, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                if !request.leftover.isEmpty {
                    try SocketIO.writeAll(upstream, request.leftover)
                }
            } else {
                try SocketIO.writeAll(upstream, request.forwardData)
            }
            handedToRelay = true
            relayTracked(
                socket: socket,
                upstream: upstream,
                host: request.destination.host,
                port: request.destination.port,
                decision: decision,
                limiter: limiter,
                generation: generation
            )
        } catch {
            guard !SocketError.isBenignDisconnect(error) else { return }
            logCallback.invoke("HTTP error: \(error.localizedDescription)", isStderr: true)
            try? SocketIO.writeAll(socket, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
        }
    }

    /// 把 fd 所有权交给 RelayHub。当前 handler 注册后立即返回，最终清理由 completion 完成。
    private func relayTracked(
        socket: Int32,
        upstream: Int32,
        host: String,
        port: Int,
        decision: RouteDecision,
        limiter: ConnectionLimiter,
        generation: UInt64
    ) {
        let recordId = Int(socket)
        Task { @MainActor in
            ConnectionTracker.shared.recordStart(
                id: recordId,
                host: host,
                port: port,
                action: decision.action,
                reason: decision.reason
            )
        }
        let byteTracker = RelayByteTracker()
        guard registerActiveSocket(upstream, generation: generation) else {
            // stop 已开始，fd 尚未交给 RelayHub，当前线程负责完整清理。
            unregisterActiveSocket(socket)
            shutdown(socket, SHUT_RDWR)
            shutdown(upstream, SHUT_RDWR)
            close(socket)
            close(upstream)
            limiter.release()
            Task { @MainActor in
                ConnectionTracker.shared.recordEnd(id: recordId)
            }
            return
        }
        SocketIO.relayTracked(socket, upstream, byteTracker: byteTracker, onTick: {
            let snapshot = byteTracker.snapshot
            Task { @MainActor in
                ConnectionTracker.shared.updateBytes(
                    id: recordId,
                    sent: snapshot.sent,
                    received: snapshot.received
                )
            }
        }, completion: { [self] in
            let snapshot = byteTracker.snapshot
            Task { @MainActor in
                ConnectionTracker.shared.updateBytes(
                    id: recordId,
                    sent: snapshot.sent,
                    received: snapshot.received
                )
                ConnectionTracker.shared.recordEnd(id: recordId)
            }
            unregisterActiveSocket(socket)
            unregisterActiveSocket(upstream)
            close(socket)
            close(upstream)
            limiter.release()
        })
    }

    /// 连接上游 naive（SOCKS5）。naive 启动期端口可能短暂未就绪，做有限重试。
    /// 用 poll 等待代替忙等 Thread.sleep，重试间隔指数增长（50ms → 100ms → 200ms...），减少 CPU 空转。
    private func connectViaNaive(naivePort: Int, destination: ProxyDestination) throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        var retried = false
        var backoffMs: Int32 = 50

        repeat {
            do {
                let socket = try SOCKS5.connectViaProxy(
                    proxyHost: "127.0.0.1",
                    proxyPort: naivePort,
                    destination: destination
                )
                if retried {
                    logCallback.invoke("upstream SOCKS recovered after retry: 127.0.0.1:\(naivePort)", isStderr: false)
                }
                return socket
            } catch {
                guard isNaiveConnectFailure(error, naivePort: naivePort), Date() < deadline else {
                    throw error
                }
                retried = true
                // poll 等待代替 Thread.sleep：指数退避（50→100→200...封顶 400ms），不占 CPU。
                _ = poll(nil, 0, backoffMs)
                backoffMs = min(backoffMs * 2, 400)
            }
        } while true
    }

    private func isNaiveConnectFailure(_ error: Error, naivePort: Int) -> Bool {
        guard case SocketError.connectFailed(let host, let port, _) = error else { return false }
        return host == "127.0.0.1" && port == naivePort
    }
}

private final class TCPServer: @unchecked Sendable {
    private struct State {
        var listenSocket: Int32
        var isRunning = false
    }

    private let host: String
    private let port: Int
    private let handler: @Sendable (Int32) -> Void
    private let queue: DispatchQueue
    private let state: LockedBox<State>

    var isRunning: Bool {
        state.withLock { $0.isRunning }
    }

    init(host: String, port: Int, handler: @escaping @Sendable (Int32) -> Void) throws {
        self.host = host
        self.port = port
        self.handler = handler
        self.queue = DispatchQueue(label: "native-routing-listener-\(port)")
        self.state = LockedBox(State(listenSocket: try SocketIO.listen(host: host, port: port)))
    }

    deinit {
        stop()
    }

    func start() {
        let shouldStart = state.withLock { state in
            guard !state.isRunning, state.listenSocket >= 0 else { return false }
            state.isRunning = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let fd = state.withLock { state -> Int32 in
            state.isRunning = false
            let fd = state.listenSocket
            state.listenSocket = -1
            return fd
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            let snapshot = state.withLock { ($0.isRunning, $0.listenSocket) }
            guard snapshot.0, snapshot.1 >= 0 else { break }
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(snapshot.1, $0, &len)
                }
            }
            if client < 0 {
                if isRunning { continue }
                break
            }
            SocketIO.disableSigPipe(client)
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                handler(client)
            }
        }
    }
}

private struct ProxyDestination {
    let host: String
    let port: Int

    var normalizedHost: String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

private enum SocketError: LocalizedError {
    case invalidAddress(String)
    case socketFailed
    case bindFailed(String, Int)
    case listenFailed
    case connectFailed(String, Int, Int32)
    case shortRead
    case invalidProtocol(String)
    case writeFailed

    static func isBenignDisconnect(_ error: Error) -> Bool {
        guard let socketError = error as? SocketError else { return false }
        switch socketError {
        case .shortRead, .writeFailed:
            return true
        case .invalidAddress, .socketFailed, .bindFailed, .listenFailed, .connectFailed, .invalidProtocol:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let host): return "invalid address: \(host)"
        case .socketFailed: return "socket creation failed"
        case .bindFailed(let host, let port): return "bind failed: \(host):\(port)"
        case .listenFailed: return "listen failed"
        case .connectFailed(let host, let port, let code):
            if code == 0 {
                return "connect failed: \(host):\(port)"
            }
            return "connect failed: \(host):\(port) (\(String(cString: strerror(code))))"
        case .shortRead: return "connection closed while reading"
        case .invalidProtocol(let reason): return "invalid protocol: \(reason)"
        case .writeFailed: return "socket write failed"
        }
    }
}

private enum SocketIO {
    static func disableSigPipe(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    static func listen(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_PASSIVE,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &result)
        guard status == 0, let first = result else { throw SocketError.invalidAddress(host) }
        defer { freeaddrinfo(first) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                disableSigPipe(fd)
                if bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    if Darwin.listen(fd, SOMAXCONN) == 0 {
                        return fd
                    }
                    close(fd)
                    throw SocketError.listenFailed
                }
                close(fd)
            }
            ptr = info.pointee.ai_next
        }
        throw SocketError.bindFailed(host, port)
    }

    static func connect(host: String, port: Int, timeoutMs: Int32 = SocketTimeout.connectMs) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &result)
        guard status == 0, let first = result else { throw SocketError.invalidAddress(host) }
        defer { freeaddrinfo(first) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        var lastErrno: Int32 = 0
        while let info = ptr {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                disableSigPipe(fd)
                // 设为非阻塞，配合 poll 实现 connect 超时。
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let connectResult = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if connectResult == 0 {
                    // 立即成功（本地连接），恢复阻塞模式。
                    _ = fcntl(fd, F_SETFL, flags)
                    return fd
                }
                if errno == EINPROGRESS {
                    // 等待可写，表示连接完成或失败。
                    if waitForSocketReady(fd, events: Int16(POLLOUT), timeoutMs: timeoutMs) {
                        var sockErr: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &len) == 0 && sockErr == 0 {
                            _ = fcntl(fd, F_SETFL, flags) // 恢复阻塞
                            return fd
                        }
                        lastErrno = sockErr
                    } else {
                        lastErrno = ETIMEDOUT
                    }
                    close(fd)
                    ptr = info.pointee.ai_next
                    continue
                }
                lastErrno = errno
                close(fd)
            }
            ptr = info.pointee.ai_next
        }
        throw SocketError.connectFailed(host, port, lastErrno)
    }

    /// 给 fd 设置接收超时（秒）。超时后 recv 返回 -1 且 errno=EWOULDBLOCK，调用方应抛 shortRead。
    static func setRecvTimeout(_ fd: Int32, seconds: Int32) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func readExact(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: offset), count - offset, 0)
            }
            if readCount <= 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw SocketError.shortRead
                }
                throw SocketError.shortRead
            }
            offset += readCount
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 { throw SocketError.writeFailed }
                offset += written
            }
        }
    }

    /// 读取 HTTP 请求头直到遇到 `\r\n\r\n`。返回 (headerData, leftover)，leftover 是 header 之后的额外字节（pipelining 的下一个请求）。
    /// 阶段2 优化：用大缓冲一次性 recv，扫描分隔符，避免逐字节 recv 的几百次系统调用。
    static func readHeader(_ fd: Int32, limit: Int = 64 * 1024) throws -> (header: Data, leftover: Data) {
        let separator: [UInt8] = [13, 10, 13, 10]
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        var accumulated = Data()
        var scanStart = 0

        while accumulated.count < limit {
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { throw SocketError.shortRead }
            accumulated.append(buffer, count: n)

            // 仅在新增字节可能补全分隔符的范围内扫描，避免 O(N^2)。
            let chunk = Data(buffer.prefix(n))
            if let range = accumulated.range(of: Data(separator), in: scanStart..<accumulated.count) {
                let headerEnd = range.upperBound
                let leftover = accumulated.subdata(in: headerEnd..<accumulated.count)
                return (accumulated.subdata(in: 0..<headerEnd), leftover)
            }
            // 下次扫描从可能跨块的分隔符起点开始（最多回退 3 字节）。
            scanStart = max(0, accumulated.count - 3)
            _ = chunk // chunk 仅作可读性占位
        }
        throw SocketError.invalidProtocol("header too large")
    }

    /// 执行双向 relay（事件驱动）。byteTracker 累计字节；onTick 在传输过程中周期性触发，
    /// 让 ConnectionTracker 实时刷新 UI。底层用 RelayHub 单线程 poll 所有连接，不再每对 fd 起 2 个 pump 线程。
    static func relayTracked(_ first: Int32, _ second: Int32,
                             byteTracker: RelayByteTracker?,
                             onTick: RelayHub.Callback? = nil,
                             completion: @escaping RelayHub.Callback) {
        RelayHub.shared.relay(
            first,
            second,
            byteTracker: byteTracker,
            onTick: onTick,
            completion: completion
        )
    }
}

/// 单条 relay 连接的上下行字节计数器。供连接表使用（阶段4）。
/// 线程安全：RelayHub 写入、UI 更新回调读取，均通过内部锁同步。
final class RelayByteTracker: @unchecked Sendable {
    enum Direction: Sendable { case sent, received }

    private var sent: Int64 = 0
    private var received: Int64 = 0
    private let lock = NSLock()

    func add(bytes: Int64, direction: Direction) {
        lock.lock()
        switch direction {
        case .sent: sent &+= bytes
        case .received: received &+= bytes
        }
        lock.unlock()
    }

    var snapshot: (sent: Int64, received: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (sent, received)
    }
}

private enum SOCKS5 {
    static func readClientRequest(from fd: Int32) throws -> ProxyDestination {
        let greeting = [UInt8](try SocketIO.readExact(fd, count: 2))
        guard greeting[0] == 0x05 else { throw SocketError.invalidProtocol("SOCKS version") }
        _ = try SocketIO.readExact(fd, count: Int(greeting[1]))
        try SocketIO.writeAll(fd, Data([0x05, 0x00]))

        let header = [UInt8](try SocketIO.readExact(fd, count: 4))
        guard header[0] == 0x05, header[1] == 0x01 else { throw SocketError.invalidProtocol("SOCKS command") }
        let host = try readAddress(from: fd, atyp: header[3])
        let portBytes = [UInt8](try SocketIO.readExact(fd, count: 2))
        let port = Int(portBytes[0]) << 8 | Int(portBytes[1])
        return ProxyDestination(host: host, port: port)
    }

    static func writeReply(to fd: Int32, status: UInt8) throws {
        try SocketIO.writeAll(fd, Data([0x05, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    }

    static func connectViaProxy(proxyHost: String, proxyPort: Int, destination: ProxyDestination) throws -> Int32 {
        let fd = try SocketIO.connect(host: proxyHost, port: proxyPort)
        do {
            try SocketIO.writeAll(fd, Data([0x05, 0x01, 0x00]))
            let response = [UInt8](try SocketIO.readExact(fd, count: 2))
            guard response == [0x05, 0x00] else { throw SocketError.invalidProtocol("upstream SOCKS auth") }

            var request = Data([0x05, 0x01, 0x00])
            appendAddress(destination.host, to: &request)
            request.append(UInt8((destination.port >> 8) & 0xff))
            request.append(UInt8(destination.port & 0xff))
            try SocketIO.writeAll(fd, request)

            let header = [UInt8](try SocketIO.readExact(fd, count: 4))
            guard header[0] == 0x05, header[1] == 0x00 else { throw SocketError.invalidProtocol("upstream SOCKS connect") }
            _ = try readAddress(from: fd, atyp: header[3])
            _ = try SocketIO.readExact(fd, count: 2)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func readAddress(from fd: Int32, atyp: UInt8) throws -> String {
        switch atyp {
        case 0x01:
            let bytes = [UInt8](try SocketIO.readExact(fd, count: 4))
            return bytes.map(String.init).joined(separator: ".")
        case 0x03:
            let length = Int([UInt8](try SocketIO.readExact(fd, count: 1))[0])
            let data = try SocketIO.readExact(fd, count: length)
            return String(data: data, encoding: .utf8) ?? ""
        case 0x04:
            let bytes = [UInt8](try SocketIO.readExact(fd, count: 16))
            var output = [String]()
            for index in stride(from: 0, to: bytes.count, by: 2) {
                output.append(String(format: "%02x%02x", bytes[index], bytes[index + 1]))
            }
            return output.joined(separator: ":")
        default:
            throw SocketError.invalidProtocol("address type")
        }
    }

    private static func appendAddress(_ host: String, to data: inout Data) {
        if let ipv4 = IPv4Address(host) {
            data.append(0x01)
            data.append(ipv4.rawValue)
        } else if let ipv6 = IPv6Address(host) {
            data.append(0x04)
            data.append(ipv6.rawValue)
        } else {
            let bytes = Array(host.utf8)
            data.append(0x03)
            data.append(UInt8(min(bytes.count, 255)))
            data.append(contentsOf: bytes.prefix(255))
        }
    }
}

private struct HTTPProxyRequest {
    let destination: ProxyDestination
    let isConnect: Bool
    let forwardData: Data
    let leftover: Data

    static func read(from fd: Int32) throws -> HTTPProxyRequest {
        let (headerData, leftover) = try SocketIO.readHeader(fd)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw SocketError.invalidProtocol("HTTP header encoding")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw SocketError.invalidProtocol("HTTP request line") }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw SocketError.invalidProtocol("HTTP request line") }

        if parts[0].uppercased() == "CONNECT" {
            let destination = parseHostPort(parts[1], defaultPort: 443)
            return HTTPProxyRequest(destination: destination, isConnect: true, forwardData: Data(), leftover: leftover)
        }

        // 解析目标 host。优先用绝对 URL（显式代理标准做法）；失败则从 Host 头 fallback。
        // 部分客户端（某些 SDK、透明代理场景）只发相对 URL + Host 头，需兼容。
        let destination: ProxyDestination
        let rewritten: String
        if let url = URL(string: parts[1]), let host = url.host {
            // 标准绝对 URL：改写为相对路径转发给上游。
            let port = url.port ?? 80
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query { path += "?\(query)" }
            let rewrittenLine = "\(parts[0]) \(path) \(parts[2])"
            var rewrittenLines = lines
            rewrittenLines[0] = rewrittenLine
            destination = ProxyDestination(host: host, port: port)
            rewritten = rewrittenLines.joined(separator: "\r\n")
        } else if let host = parseHostHeader(lines) {
            // 相对 URL + Host 头：请求行已是相对路径，原样转发，不改写。
            destination = parseHostPort(host, defaultPort: 80)
            rewritten = lines.joined(separator: "\r\n")
        } else {
            throw SocketError.invalidProtocol("HTTP target host (no absolute URL and no Host header)")
        }
        // leftover 是 header 之后已读到的字节（可能是 POST body 前缀或 pipelining 的下一个请求），拼到转发数据前。
        let forward = Data(rewritten.utf8) + leftover
        return HTTPProxyRequest(
            destination: destination,
            isConnect: false,
            forwardData: forward,
            leftover: Data()
        )
    }

    /// 从 header 行里提取 Host 值（不区分大小写）。返回不含端口的部分由调用方 parseHostPort 处理。
    private static func parseHostHeader(_ lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "host" {
                let value = String(line[line.index(after: colonIdx)...])
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func parseHostPort(_ value: String, defaultPort: Int) -> ProxyDestination {
        if value.hasPrefix("["),
           let end = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<end])
            let portStart = value.index(after: end)
            if portStart < value.endIndex, value[portStart] == ":" {
                let rawPort = String(value[value.index(after: portStart)...])
                return ProxyDestination(host: host, port: Int(rawPort) ?? defaultPort)
            }
            return ProxyDestination(host: host, port: defaultPort)
        }
        if let idx = value.lastIndex(of: ":") {
            let host = String(value[..<idx])
            let port = Int(value[value.index(after: idx)...]) ?? defaultPort
            return ProxyDestination(host: host, port: port)
        }
        return ProxyDestination(host: value, port: defaultPort)
    }
}

/// 值本身初始化后不可变；唯一的引用成员 RuleSetStore 对内部可变状态加锁。
private struct NativeRouteMatcher: @unchecked Sendable {
    private let defaultOutbound: RuleAction
    private let entries: [Entry]
    private let requiredRuleSetTags: Set<String>
    private let ruleSetStore: RuleSetStore
    private let logger: ((String, Bool) -> Void)?

    init(defaultOutbound: RuleAction, rules: [RoutingRule], ruleSetStore: RuleSetStore, logger: ((String, Bool) -> Void)? = nil) {
        self.defaultOutbound = defaultOutbound
        self.entries = rules.flatMap { rule in
            rule.conditions.map { Entry(ruleName: rule.name, action: rule.type, condition: $0) }
        }
        self.requiredRuleSetTags = Set(entries.compactMap { entry -> String? in
            entry.condition.field == .ruleSet ? entry.condition.value : nil
        })
        self.ruleSetStore = ruleSetStore
        self.logger = logger
    }

    /// 按用户排列的规则顺序匹配，保持规则的相对优先级（而非按规则类型分轮）。
    /// 域名类规则（domain/domainSuffix/domainKeyword）无需 IP 立即可判；
    /// IP 类规则（ipCidr/ruleSet）需要 IP，若当前 destination 是域名则惰性解析。
    /// 解析结果缓存到 resolvedIPs，避免同一次判定里重复查询；多 IP 时每条 IP 规则
    /// 遍历所有解析结果，命中后把"具体命中的 IP"回传给连接层（直连时用，避免用错 IP）。
    func decision(for destination: ProxyDestination) -> RouteDecision {
        var resolvedIPs: [String]? = nil  // 惰性：仅当遇到 IP 类规则且 host 是域名时才解析

        for entry in entries {
            switch entry.condition.field {
            case .domain, .domainSuffix, .domainKeyword:
                if matchesDomainOnly(entry.condition, destination: destination) {
                    return RouteDecision(action: entry.action, reason: "rule: \(entry.ruleName)")
                }
            case .ipCidr:
                // 需 IP。若 host 是 IP 字面量直接用；否则按需解析一次，复用结果。
                if resolvedIPs == nil {
                    resolvedIPs = resolveIfNeeded(destination)
                }
                if let hitIP = matchIpCidr(entry.condition, resolvedIPs: resolvedIPs ?? []) {
                    return RouteDecision(action: entry.action, reason: "rule: \(entry.ruleName)", resolvedIP: hitIP)
                }
            case .ruleSet:
                // ruleSet 同时含域名与 IP，且可能带 invert/AND。
                // 先做安全的纯域名预检（无 DoH）：仅对无 invert 且 OR 的规则集生效，
                // 避免 invert 规则集在"无 IP"时误命中所有域名。
                if let matcher = ruleSetStore.matcher(for: entry.condition.value),
                   matcher.matchesDomainSafe(destination: destination) {
                    return RouteDecision(action: entry.action, reason: "rule: \(entry.ruleName)")
                }
                // 域名预检未中（或 invert/AND 需 IP 才能定论）：解析 IP 后走完整 matches。
                if resolvedIPs == nil {
                    resolvedIPs = resolveIfNeeded(destination)
                }
                if let matcher = ruleSetStore.matcher(for: entry.condition.value),
                   let hitIP = matcher.matchingIP(destination: destination, resolvedIPs: resolvedIPs ?? []) {
                    return RouteDecision(action: entry.action, reason: "rule: \(entry.ruleName)", resolvedIP: hitIP)
                }
            }
        }

        if !ruleSetStore.allLoaded(tags: requiredRuleSetTags) {
            return RouteDecision(action: defaultOutbound, reason: "default; rule sets loading", resolvedIP: resolvedIPs?.first)
        }
        return RouteDecision(action: defaultOutbound, reason: "default", resolvedIP: resolvedIPs?.first)
    }

    /// ipCidr 规则匹配。返回命中的 IP（用于直连时连接），未命中返回 nil。
    private func matchIpCidr(_ condition: RuleCondition, resolvedIPs: [String]) -> String? {
        guard let cidr = IPCIDR(condition.value) else { return nil }
        for ip in resolvedIPs {
            guard let parsed = IPAddress(ip) else { continue }
            if cidr.contains(parsed) {
                return ip
            }
        }
        return nil
    }

    func ruleSetStatuses(for tags: Set<String>) -> [String: RuleSetLoadStatus] {
        ruleSetStore.statuses(for: tags)
    }

    func preloadRuleSets() {
        guard !requiredRuleSetTags.isEmpty else {
            ruleSetStore.logRuleSetSummary(tags: requiredRuleSetTags)
            return
        }
        let group = DispatchGroup()
        for tag in requiredRuleSetTags.sorted() {
            group.enter()
            ruleSetStore.loadInBackground(tag: tag) {
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) {
            ruleSetStore.logRuleSetSummary(tags: requiredRuleSetTags)
        }
    }

    /// 域名类规则匹配（domain/domainSuffix/domainKeyword）。不需要 IP。
    private func matchesDomainOnly(_ condition: RuleCondition, destination: ProxyDestination) -> Bool {
        let host = destination.normalizedHost
        switch condition.field {
        case .domain:
            return host == condition.value.lowercased()
        case .domainSuffix:
            let suffix = condition.value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == suffix || host.hasSuffix(".\(suffix)")
        case .domainKeyword:
            return host.contains(condition.value.lowercased())
        case .ipCidr, .ruleSet:
            return false
        }
    }

    /// 若 destination.host 是域名且 DoH 启用，解析成 IP。已是 IP 则直接返回。
    /// 用非阻塞的 resolveCached：命中缓存立即返回，未命中触发后台 prefetch 并返回空——
    /// 路由判定线程不再因等 DoH 而卡住。代价是某域名首次访问时 IP 类规则暂不生效，
    /// 按域名规则/默认 outbound 处理；DoH 完成后缓存生效，后续连接即命中 IP 规则。
    /// DoH 未启用或尚未解析完成时返回空数组（调用方据此跳过 IP 规则）。
    private func resolveIfNeeded(_ destination: ProxyDestination) -> [String] {
        // 已经是 IP 字面量。
        if IPAddress(destination.host) != nil {
            return [destination.host]
        }
        let ips = DNSResolver.shared.resolveCached(destination.host)
        if ips.isEmpty {
            logger?("DoH not ready for \(destination.host); using domain rules this time", true)
        } else {
            // 只显示第一个 IP，避免多 IP 时日志过长。
            logger?("DoH \(destination.host) -> \(ips[0])" + (ips.count > 1 ? " (+\(ips.count - 1) more)" : ""), false)
        }
        return ips
    }

    private struct Entry {
        let ruleName: String
        let action: RuleAction
        let condition: RuleCondition
    }
}

private struct RouteDecision {
    let action: RuleAction
    let reason: String
    /// DoH 解析出的 IP（若有）。handleSOCKS/handleHTTP 可据此用 IP 而非域名连接，避免二次 DNS。
    let resolvedIP: String?

    init(action: RuleAction, reason: String, resolvedIP: String? = nil) {
        self.action = action
        self.reason = reason
        self.resolvedIP = resolvedIP
    }

    var logAction: String {
        action.rawValue.uppercased()
    }
}

private final class RuleSetStore: @unchecked Sendable {
    private let cacheDirectory: URL
    private let logger: @Sendable (String, Bool) -> Void
    private var matchers: [String: RuleSetMatcher] = [:]
    private var loadingTags = Set<String>()
    private var failedTags = Set<String>()
    private let lock = NSLock()

    init(cacheDirectory: URL, logger: @escaping @Sendable (String, Bool) -> Void) {
        self.cacheDirectory = cacheDirectory
        self.logger = logger
    }

    func matcher(for tag: String) -> RuleSetMatcher? {
        lock.lock()
        let matcher = matchers[tag]
        lock.unlock()
        return matcher
    }

    func allLoaded(tags: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tags.allSatisfy { matchers[$0] != nil }
    }

    func statuses(for tags: Set<String>) -> [String: RuleSetLoadStatus] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: tags.map { tag in
            let status: RuleSetLoadStatus
            if matchers[tag] != nil {
                status = .ready
            } else if loadingTags.contains(tag) {
                status = .loading
            } else if failedTags.contains(tag) {
                status = .failed
            } else {
                status = .notLoaded
            }
            return (tag, status)
        })
    }

    func loadInBackground(tag: String, completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if matchers[tag] != nil {
            lock.unlock()
            completion()
            return
        }
        if loadingTags.contains(tag) {
            lock.unlock()
            completion()
            return
        }
        loadingTags.insert(tag)
        lock.unlock()
        notifyStatusDidChange()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.load(tag: tag)
            completion()
        }
    }

    func logRuleSetSummary(tags: Set<String>) {
        lock.lock()
        let loaded = tags.filter { matchers[$0] != nil }.sorted()
        let failed = tags.filter { failedTags.contains($0) }.sorted()
        let stillLoading = tags.filter { loadingTags.contains($0) }.sorted()
        lock.unlock()

        if tags.isEmpty {
            logger("rule-set preload complete: no rule sets configured", false)
        } else if failed.isEmpty && stillLoading.isEmpty && loaded.count == tags.count {
            logger("rule-set preload complete: all \(loaded.count) rule sets ready", false)
        } else {
            let failedList = failed.joined(separator: ", ")
            logger("rule-set preload incomplete: loaded \(loaded.count)/\(tags.count), failed: \(failedList)", true)
        }
    }

    private func load(tag: String) {
        do {
            let matcher = try loadMatcher(tag: tag)
            lock.lock()
            matchers[tag] = matcher
            failedTags.remove(tag)
            loadingTags.remove(tag)
            lock.unlock()
            logger("rule-set \(tag) ready", false)
            notifyStatusDidChange()
        } catch {
            lock.lock()
            failedTags.insert(tag)
            loadingTags.remove(tag)
            lock.unlock()
            logger("rule-set \(tag) unavailable: \(error.localizedDescription)", true)
            notifyStatusDidChange()
        }
    }

    private func notifyStatusDidChange() {
        NativeRoutingProxyManager.notifyRuleSetStatusDidChange()
    }

    private func loadMatcher(tag: String) throws -> RuleSetMatcher {
        let fileURL = cacheDirectory.appendingPathComponent("\(tag).srs")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            logger("loaded cached rule-set \(tag)", false)
            do {
                return try SRSParser.parse(data)
            } catch {
                logger("cached rule-set \(tag) invalid, falling back to bundled copy: \(error.localizedDescription)", true)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        if let bundledURL = Bundle.main.url(forResource: tag, withExtension: "srs", subdirectory: "rule-sets") {
            let data = try Data(contentsOf: bundledURL)
            logger("loaded bundled rule-set \(tag)", false)
            return try SRSParser.parse(data)
        }

        guard let url = Self.remoteURL(for: tag) else {
            throw SocketError.invalidProtocol("unknown rule-set tag")
        }
        logger("downloading rule-set \(tag)", false)
        let data = try Data(contentsOf: url)
        try data.write(to: fileURL, options: .atomic)
        return try SRSParser.parse(data)
    }

    static func remoteURL(for tag: String) -> URL? {
        if tag.hasPrefix("geoip") {
            return URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/\(tag).srs")
        }
        if tag.hasPrefix("geosite") {
            return URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/\(tag).srs")
        }
        return nil
    }
}

private struct RuleSetMatcher {
    var domainMatchers: [DomainMatcher] = []
    var keywords: [String] = []
    var cidrs: [IPCIDR] = []
    var subRules: [RuleSetMatcher] = []
    var mode: LogicalMode = .or
    var invert = false

    enum LogicalMode {
        case and
        case or
    }

    /// 匹配。域名部分用 destination 的 host，IP 部分用 resolvedIPs（DoH 解析结果）。
    /// 若 resolvedIPs 为空（DoH 未启用或解析失败），IP 规则静默不命中，仅靠域名规则判定。
    func matches(destination: ProxyDestination, resolvedIPs: [String] = []) -> Bool {
        let host = destination.normalizedHost
        var result = false

        if !result {
            result = domainMatchers.contains { $0.matches(host) }
        }
        if !result {
            result = keywords.contains { host.contains($0) }
        }
        if !result, !resolvedIPs.isEmpty {
            result = cidrs.contains { cidr in
                resolvedIPs.contains { ip in
                    guard let parsed = IPAddress(ip) else { return false }
                    return cidr.contains(parsed)
                }
            }
        }
        if !subRules.isEmpty {
            switch mode {
            case .or:
                result = result || subRules.contains { $0.matches(destination: destination, resolvedIPs: resolvedIPs) }
            case .and:
                result = result || subRules.allSatisfy { $0.matches(destination: destination, resolvedIPs: resolvedIPs) }
            }
        }
        return invert ? !result : result
    }

    /// 返回命中的具体 IP（用于直连时连接正确目标）。
    /// 先用完整 matches 判定是否命中（正确处理 invert/AND/子规则的完整语义），
    /// 命中后再从 resolvedIPs 中找出实际落在某 cidr 内的 IP。
    /// 若规则集因 invert 等原因命中但无具体 IP（如纯域名命中），返回 resolvedIPs.first 作为兜底。
    func matchingIP(destination: ProxyDestination, resolvedIPs: [String]) -> String? {
        // 先用完整语义判定是否命中。
        guard matches(destination: destination, resolvedIPs: resolvedIPs) else { return nil }
        // 命中了，找出具体落在 cidr 内的 IP（本规则集或子规则）。
        if let hit = findMatchingIP(resolvedIPs: resolvedIPs) {
            return hit
        }
        // 命中但不是靠 IP 规则命中的（如域名命中或 invert 命中），返回首个 IP 兜底。
        return resolvedIPs.first
    }

    /// 安全的纯域名预检（无 DoH）。仅当规则集**无 invert 且为 OR 模式**时才判定，
    /// 因为这类规则集的语义在"只有域名、无 IP"时仍然正确（域名命中即可决定结果）。
    /// 对 invert 规则集：无 IP 时所有子项返回 false，反转后变 true，会误命中所有域名——必须跳过。
    /// 对 AND 规则集：缺 IP 子项一定不满足，纯域名视角无法判定——必须跳过。
    /// 跳过的规则集由调用方在解析 IP 后走完整 matches 兜底。
    func matchesDomainSafe(destination: ProxyDestination) -> Bool {
        guard !invert, mode == .or else { return false }
        let host = destination.normalizedHost
        if domainMatchers.contains(where: { $0.matches(host) }) { return true }
        if keywords.contains(where: { host.contains($0) }) { return true }
        return subRules.contains { $0.matchesDomainSafe(destination: destination) }
    }

    /// 递归查找落在任意 cidr（含子规则）内的 IP。
    private func findMatchingIP(resolvedIPs: [String]) -> String? {
        for cidr in cidrs {
            for ip in resolvedIPs {
                guard let parsed = IPAddress(ip) else { continue }
                if cidr.contains(parsed) {
                    return ip
                }
            }
        }
        for sub in subRules {
            if let hit = sub.findMatchingIP(resolvedIPs: resolvedIPs) {
                return hit
            }
        }
        return nil
    }
}

struct IPAddress: Comparable {
    let bytes: [UInt8]

    init?(_ string: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, string, &ipv4) == 1 {
            let raw = withUnsafeBytes(of: ipv4.s_addr, Array.init)
            bytes = raw
            return
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, string, &ipv6) == 1 {
            bytes = withUnsafeBytes(of: ipv6.__u6_addr.__u6_addr8, Array.init)
            return
        }
        return nil
    }

    static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.bytes.count != rhs.bytes.count { return lhs.bytes.count < rhs.bytes.count }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

struct IPCIDR {
    let network: IPAddress
    let bits: Int
    let rangeEnd: IPAddress?

    init?(_ string: String) {
        // omittingEmptySubsequences: false 让 "1.2.3.4/" 保留空前缀，便于检测非法。
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let address = IPAddress(parts[0]) else { return nil }
        let maxBits = address.bytes.count * 8
        let prefix: Int?
        if parts.count == 2 {
            // 有 "/" 但前缀为空（如 "1.2.3.4/"）应视为非法。
            guard !parts[1].isEmpty, let p = Int(parts[1]) else { return nil }
            prefix = p
        } else {
            prefix = maxBits
        }
        guard let prefix, prefix >= 0, prefix <= maxBits else { return nil }
        network = address
        bits = prefix
        rangeEnd = nil
    }

    init(rangeStart: IPAddress, rangeEnd: IPAddress) {
        network = rangeStart
        self.rangeEnd = rangeEnd
        bits = rangeStart.bytes.count * 8
    }

    func contains(_ address: IPAddress) -> Bool {
        guard address.bytes.count == network.bytes.count else { return false }
        if let rangeEnd {
            return network <= address && address <= rangeEnd
        }
        let fullBytes = bits / 8
        let remainingBits = bits % 8
        if fullBytes > 0 && address.bytes.prefix(fullBytes) != network.bytes.prefix(fullBytes) {
            return false
        }
        if remainingBits == 0 { return true }
        let mask = UInt8(0xff << UInt8(8 - remainingBits))
        return (address.bytes[fullBytes] & mask) == (network.bytes[fullBytes] & mask)
    }
}

private enum SRSParser {
    static func parse(_ data: Data) throws -> RuleSetMatcher {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0x53, bytes[1] == 0x52, bytes[2] == 0x53 else {
            throw SocketError.invalidProtocol("invalid SRS magic")
        }
        let compressed = Data(bytes.dropFirst(4))
        let inflated = try compressed.zlibInflated()
        var reader = BinaryReader([UInt8](inflated))
        let count = try reader.readUvarint()
        var matcher = RuleSetMatcher()
        for _ in 0..<count {
            matcher.subRules.append(try readRule(&reader))
        }
        return matcher
    }

    private static func readRule(_ reader: inout BinaryReader) throws -> RuleSetMatcher {
        let type = try reader.readByte()
        switch type {
        case 0:
            return try readDefaultRule(&reader)
        case 1:
            return try readLogicalRule(&reader)
        default:
            throw SocketError.invalidProtocol("unknown SRS rule type")
        }
    }

    private static func readDefaultRule(_ reader: inout BinaryReader) throws -> RuleSetMatcher {
        var matcher = RuleSetMatcher()
        while true {
            let item = try reader.readByte()
            switch item {
            case 0, 1:
                _ = try reader.readUInt16List()
            case 2:
                let domainMatcher = try DomainMatcher.read(from: &reader)
                matcher.domainMatchers.append(domainMatcher)
            case 3:
                matcher.keywords.append(contentsOf: try reader.readStringList().map { $0.lowercased() })
            case 4:
                _ = try reader.readStringList()
            case 5:
                _ = try reader.readIPSetCIDRs()
            case 6:
                matcher.cidrs.append(contentsOf: try reader.readIPSetCIDRs())
            case 7, 9:
                _ = try reader.readUInt16List()
            case 8, 10, 11, 12, 13, 14, 15, 17, 23:
                _ = try reader.readStringList()
            case 18:
                _ = try reader.readUInt8List()
            case 19, 20:
                break
            case 0xff:
                matcher.invert = try reader.readByte() != 0
                return matcher
            default:
                throw SocketError.invalidProtocol("unsupported SRS item \(item)")
            }
        }
    }

    private static func readLogicalRule(_ reader: inout BinaryReader) throws -> RuleSetMatcher {
        let mode = try reader.readByte()
        let count = try reader.readUvarint()
        var matcher = RuleSetMatcher()
        matcher.mode = mode == 0 ? .and : .or
        for _ in 0..<count {
            matcher.subRules.append(try readRule(&reader))
        }
        matcher.invert = try reader.readByte() != 0
        return matcher
    }
}

private struct DomainMatcher {
    let set: SuccinctSet

    static func read(from reader: inout BinaryReader) throws -> DomainMatcher {
        _ = try reader.readByte()
        let leaves = try reader.readUInt64List()
        let labelBitmap = try reader.readUInt64List()
        let labels = try reader.readBytes(count: Int(reader.readUvarint()))
        return DomainMatcher(set: SuccinctSet(leaves: leaves, labelBitmap: labelBitmap, labels: labels))
    }

    func matches(_ host: String) -> Bool {
        set.matches(Array(String(host.reversed()).utf8))
    }
}

private struct SuccinctSet {
    let leaves: [UInt64]
    let labelBitmap: [UInt64]
    let labels: [UInt8]
    /// 预计算：labelBitmap 中值为 1 的 bit 索引列表。matches/keys 原本每次都重新扫描，
    /// 对大规则集（几万条域名）是高频热路径，预计算后只算一次。
    let onePositions: [Int]
    /// 预计算：prefixZeros[i] = labelBitmap[0..<i) 中 0 的个数。
    /// 让 countZeros(upTo:) 从 O(N) 降到 O(1)。
    let prefixZeros: [Int]

    init(leaves: [UInt64], labelBitmap: [UInt64], labels: [UInt8]) {
        self.leaves = leaves
        self.labelBitmap = labelBitmap
        self.labels = labels
        // 计算所有 1 的位置。
        var ones: [Int] = []
        let totalBits = labelBitmap.count * 64
        ones.reserveCapacity(totalBits / 4)
        for idx in 0..<totalBits where labelBitmap.bit(at: idx) {
            ones.append(idx)
        }
        self.onePositions = ones
        // 计算 prefix zeros：prefixZeros[i] = [0, i) 内 0 的个数。长度 = totalBits + 1。
        var zeros = [Int](repeating: 0, count: totalBits + 1)
        for idx in 0..<totalBits {
            zeros[idx + 1] = zeros[idx] + (labelBitmap.bit(at: idx) ? 0 : 1)
        }
        self.prefixZeros = zeros
    }

    func matches(_ key: [UInt8]) -> Bool {
        guard !labelBitmap.isEmpty else { return false }

        func startIndex(for nodeId: Int) -> Int {
            guard nodeId == 0 || nodeId - 1 < onePositions.count else { return labelBitmap.count * 64 }
            return nodeId == 0 ? 0 : onePositions[nodeId - 1] + 1
        }

        // O(1) prefix zeros 查询。
        func countZeros(upTo bitIndex: Int) -> Int {
            // bitIndex 可能因 bmIdx+1 越界一帧，prefixZeros 长度是 totalBits+1 容纳了这种情况。
            guard bitIndex >= 0, bitIndex < prefixZeros.count else {
                return bitIndex < 0 ? 0 : prefixZeros.last ?? 0
            }
            return prefixZeros[bitIndex]
        }

        var nodeId = 0
        var bmIdx = 0

        for currentChar in key {
            while true {
                guard !labelBitmap.bit(at: bmIdx) else { return false }
                let labelIndex = bmIdx - nodeId
                guard labelIndex >= 0, labelIndex < labels.count else { return false }
                let nextLabel = labels[labelIndex]
                if nextLabel == 13 {
                    return true
                }
                if nextLabel == 10 {
                    let nextNodeId = countZeros(upTo: bmIdx + 1)
                    if currentChar == UInt8(ascii: "."), leaves.bit(at: nextNodeId) {
                        return true
                    }
                }
                if nextLabel == currentChar {
                    break
                }
                bmIdx += 1
            }

            nodeId = countZeros(upTo: bmIdx + 1)
            bmIdx = startIndex(for: nodeId)
        }

        if leaves.bit(at: nodeId) {
            return true
        }
        while true {
            guard !labelBitmap.bit(at: bmIdx) else { return false }
            let labelIndex = bmIdx - nodeId
            guard labelIndex >= 0, labelIndex < labels.count else { return false }
            let nextLabel = labels[labelIndex]
            if nextLabel == 13 || nextLabel == 10 {
                return true
            }
            bmIdx += 1
        }
    }

    func keys() -> [[UInt8]] {
        func startIndex(for nodeId: Int) -> Int {
            nodeId == 0 ? 0 : onePositions[nodeId - 1] + 1
        }
        func countZeros(upTo bitIndex: Int) -> Int {
            guard bitIndex >= 0, bitIndex < prefixZeros.count else {
                return bitIndex < 0 ? 0 : prefixZeros.last ?? 0
            }
            return prefixZeros[bitIndex]
        }

        var result: [[UInt8]] = []
        var current: [UInt8] = []

        func traverse(nodeId: Int) {
            if leaves.bit(at: nodeId) {
                result.append(current)
            }
            var bmIdx = startIndex(for: nodeId)
            while !labelBitmap.bit(at: bmIdx) {
                let labelIndex = bmIdx - nodeId
                guard labelIndex >= 0, labelIndex < labels.count else { return }
                current.append(labels[labelIndex])
                traverse(nodeId: countZeros(upTo: bmIdx + 1))
                current.removeLast()
                bmIdx += 1
            }
        }

        traverse(nodeId: 0)
        return result
    }
}

private struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw SocketError.shortRead }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard offset + count <= bytes.count else { throw SocketError.shortRead }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUvarint() throws -> UInt64 {
        var x: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try readByte()
            if b < 0x80 {
                return x | UInt64(b) << shift
            }
            x |= UInt64(b & 0x7f) << shift
            shift += 7
            if shift >= 64 { throw SocketError.invalidProtocol("varint overflow") }
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let raw = try readBytes(count: 8)
        return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readString() throws -> String {
        let length = Int(try readUvarint())
        let data = try readBytes(count: length)
        return String(data: Data(data), encoding: .utf8) ?? ""
    }

    mutating func readStringList() throws -> [String] {
        let count = try readUvarint()
        var values: [String] = []
        for _ in 0..<count {
            values.append(try readString())
        }
        return values
    }

    mutating func readUInt8List() throws -> [UInt8] {
        let count = try readUvarint()
        var values: [UInt8] = []
        for _ in 0..<count {
            values.append(try readByte())
        }
        return values
    }

    mutating func readUInt16List() throws -> [UInt16] {
        let count = try readUvarint()
        var values: [UInt16] = []
        for _ in 0..<count {
            let raw = try readBytes(count: 2)
            values.append(UInt16(raw[0]) << 8 | UInt16(raw[1]))
        }
        return values
    }

    mutating func readUInt64List() throws -> [UInt64] {
        let count = try readUvarint()
        var values: [UInt64] = []
        for _ in 0..<count {
            values.append(try readUInt64())
        }
        return values
    }

    mutating func readIPSetCIDRs() throws -> [IPCIDR] {
        let version = try readByte()
        guard version == 1 else { throw SocketError.invalidProtocol("IP set version") }
        let count = Int(try readUInt64())
        var cidrs: [IPCIDR] = []
        for _ in 0..<count {
            let fromLength = Int(try readUvarint())
            let from = IPAddress(bytes: try readBytes(count: fromLength))
            let toLength = Int(try readUvarint())
            let to = IPAddress(bytes: try readBytes(count: toLength))
            cidrs.append(IPCIDR(rangeStart: from, rangeEnd: to))
        }
        return cidrs
    }
}

extension IPAddress {
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

private extension Array where Element == UInt64 {
    /// 取第 index 位的值。**越界时返回 true**（非 false）——这是 SuccinctSet 前缀树遍历的有意设计：
    /// labelBitmap 的 1 表示"节点边界/终止"，越界视为终止可让遍历循环正确退出而非死循环。
    /// matches() 里的 `guard !labelBitmap.bit(at: bmIdx) else { return false }` 依赖此语义。
    func bit(at index: Int) -> Bool {
        guard index >= 0, index >> 6 < count else { return true }
        return (self[index >> 6] & (UInt64(1) << UInt64(index & 63))) != 0
    }
}

private extension Data {
    func zlibInflated() throws -> Data {
        guard !isEmpty else { return Data() }

        var stream = z_stream()
        let initStatus = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw SocketError.invalidProtocol("zlib init")
        }
        defer { inflateEnd(&stream) }

        return try withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                return Data()
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source)
            stream.avail_in = uInt(count)

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var status: Int32
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let written = buffer.count - Int(stream.avail_out)
                if written > 0 {
                    result.append(buffer, count: written)
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw SocketError.invalidProtocol("zlib data")
            }
            return result
        }
    }
}
