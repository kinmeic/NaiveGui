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

final class NativeRoutingProxyManager {
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

    private var socksServer: TCPServer?
    private var httpServer: TCPServer?
    private var router: NativeRouteMatcher?
    private let appSupportURL: URL

    var isRunning: Bool {
        socksServer?.isRunning == true || httpServer?.isRunning == true
    }

    var onLogLine: ((String, Bool) -> Void)?
    var onUnexpectedExit: (() -> Void)?

    func ruleSetStatuses(for tags: Set<String>) -> [String: RuleSetLoadStatus] {
        guard let router else {
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
        for tag in builtInRuleSetTags {
            guard let url = RuleSetStore.remoteURL(for: tag) else { continue }
            let data = try Data(contentsOf: url)
            try data.write(to: cacheURL.appendingPathComponent("\(tag).srs"), options: .atomic)
        }
        notifyRuleSetStatusDidChange()
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
        rules: [RoutingRule]
    ) throws {
        guard !isRunning else { return }

        let cacheURL = Self.ruleSetCacheDirectory()
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let routeMatcher = NativeRouteMatcher(
            defaultOutbound: defaultOutbound,
            rules: rules,
            ruleSetStore: RuleSetStore(cacheDirectory: cacheURL) { [weak self] line, isError in
                self?.onLogLine?(line, isError)
            }
        )
        router = routeMatcher

        let socks = try TCPServer(host: routingListenAddress, port: routingPort) { [weak self] socket in
            self?.handleSOCKS(socket: socket, naivePort: naivePort)
        }
        let http = try TCPServer(host: routingListenAddress, port: routingHTTPPort) { [weak self] socket in
            self?.handleHTTP(socket: socket, naivePort: naivePort)
        }

        socksServer = socks
        httpServer = http
        socks.start()
        http.start()
        onLogLine?("native routing SOCKS listening on \(routingListenAddress):\(routingPort)", false)
        onLogLine?("native routing HTTP listening on \(routingListenAddress):\(routingHTTPPort)", false)
        routeMatcher.preloadRuleSets()
    }

    func stop() {
        socksServer?.stop()
        httpServer?.stop()
        socksServer = nil
        httpServer = nil
        router = nil
        Self.notifyRuleSetStatusDidChange()
    }

    private func handleSOCKS(socket: Int32, naivePort: Int) {
        defer { close(socket) }
        do {
            let destination = try SOCKS5.readClientRequest(from: socket)
            onLogLine?("SOCKS \(destination.host):\(destination.port) accepted", false)
            let decision = router?.decision(for: destination) ?? RouteDecision(action: .proxy, reason: "fallback")
            onLogLine?("SOCKS \(destination.host):\(destination.port) -> \(decision.logAction) (\(decision.reason))", false)

            guard decision.action != .block else {
                try SOCKS5.writeReply(to: socket, status: 0x02)
                return
            }

            let upstream: Int32
            if decision.action == .proxy {
                upstream = try connectViaNaive(naivePort: naivePort, destination: destination)
            } else {
                upstream = try SocketIO.connect(host: destination.host, port: destination.port)
            }
            defer { close(upstream) }

            try SOCKS5.writeReply(to: socket, status: 0x00)
            SocketIO.relay(socket, upstream)
        } catch {
            guard !SocketError.isBenignDisconnect(error) else { return }
            onLogLine?("SOCKS error: \(error.localizedDescription)", true)
            try? SOCKS5.writeReply(to: socket, status: 0x01)
        }
    }

    private func handleHTTP(socket: Int32, naivePort: Int) {
        defer { close(socket) }
        do {
            let request = try HTTPProxyRequest.read(from: socket)
            onLogLine?("HTTP \(request.destination.host):\(request.destination.port) accepted", false)
            let decision = router?.decision(for: request.destination) ?? RouteDecision(action: .proxy, reason: "fallback")
            onLogLine?("HTTP \(request.destination.host):\(request.destination.port) -> \(decision.logAction) (\(decision.reason))", false)

            guard decision.action != .block else {
                try SocketIO.writeAll(socket, Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                return
            }

            let upstream: Int32
            if decision.action == .proxy {
                upstream = try connectViaNaive(naivePort: naivePort, destination: request.destination)
            } else {
                upstream = try SocketIO.connect(host: request.destination.host, port: request.destination.port)
            }
            defer { close(upstream) }

            if request.isConnect {
                try SocketIO.writeAll(socket, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                if !request.leftover.isEmpty {
                    try SocketIO.writeAll(upstream, request.leftover)
                }
            } else {
                try SocketIO.writeAll(upstream, request.forwardData)
            }
            SocketIO.relay(socket, upstream)
        } catch {
            guard !SocketError.isBenignDisconnect(error) else { return }
            onLogLine?("HTTP error: \(error.localizedDescription)", true)
            try? SocketIO.writeAll(socket, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
        }
    }

    private func connectViaNaive(naivePort: Int, destination: ProxyDestination) throws -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        var retried = false

        repeat {
            do {
                let socket = try SOCKS5.connectViaProxy(
                    proxyHost: "127.0.0.1",
                    proxyPort: naivePort,
                    destination: destination
                )
                if retried {
                    onLogLine?("upstream SOCKS recovered after retry: 127.0.0.1:\(naivePort)", false)
                }
                return socket
            } catch {
                guard isNaiveConnectFailure(error, naivePort: naivePort), Date() < deadline else {
                    throw error
                }
                retried = true
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while true
    }

    private func isNaiveConnectFailure(_ error: Error, naivePort: Int) -> Bool {
        guard case SocketError.connectFailed(let host, let port, _) = error else { return false }
        return host == "127.0.0.1" && port == naivePort
    }
}

private final class TCPServer {
    private let host: String
    private let port: Int
    private let handler: (Int32) -> Void
    private let queue: DispatchQueue
    private var listenSocket: Int32 = -1
    private(set) var isRunning = false

    init(host: String, port: Int, handler: @escaping (Int32) -> Void) throws {
        self.host = host
        self.port = port
        self.handler = handler
        self.queue = DispatchQueue(label: "native-routing-listener-\(port)")
        listenSocket = try SocketIO.listen(host: host, port: port)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        isRunning = false
        if listenSocket >= 0 {
            shutdown(listenSocket, SHUT_RDWR)
            close(listenSocket)
            listenSocket = -1
        }
    }

    private func acceptLoop() {
        while isRunning {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenSocket, $0, &len)
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

    static func connect(host: String, port: Int) throws -> Int32 {
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
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                lastErrno = errno
                close(fd)
            }
            ptr = info.pointee.ai_next
        }
        throw SocketError.connectFailed(host, port, lastErrno)
    }

    static func readExact(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: offset), count - offset, 0)
            }
            if readCount <= 0 { throw SocketError.shortRead }
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

    static func readHeader(_ fd: Int32, limit: Int = 64 * 1024) throws -> Data {
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while data.count < limit {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 { throw SocketError.shortRead }
            data.append(byte[0])
            if data.count >= 4 && data.suffix(4) == Data([13, 10, 13, 10]) {
                return data
            }
        }
        throw SocketError.invalidProtocol("header too large")
    }

    static func relay(_ first: Int32, _ second: Int32) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(from: first, to: second)
            shutdown(second, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(from: second, to: first)
            shutdown(first, SHUT_WR)
            group.leave()
        }
        group.wait()
    }

    private static func pump(from input: Int32, to output: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(input, &buffer, buffer.count, 0)
            if n <= 0 { return }
            var offset = 0
            while offset < n {
                let written = send(output, buffer.withUnsafeBytes { $0.baseAddress!.advanced(by: offset) }, n - offset, 0)
                if written <= 0 { return }
                offset += written
            }
        }
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
        let headerData = try SocketIO.readHeader(fd)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw SocketError.invalidProtocol("HTTP header encoding")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw SocketError.invalidProtocol("HTTP request line") }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw SocketError.invalidProtocol("HTTP request line") }

        if parts[0].uppercased() == "CONNECT" {
            let destination = parseHostPort(parts[1], defaultPort: 443)
            return HTTPProxyRequest(destination: destination, isConnect: true, forwardData: Data(), leftover: Data())
        }

        guard let url = URL(string: parts[1]), let host = url.host else {
            throw SocketError.invalidProtocol("absolute HTTP URL")
        }
        let port = url.port ?? 80
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?\(query)" }
        let rewrittenLine = "\(parts[0]) \(path) \(parts[2])"
        var rewrittenLines = lines
        rewrittenLines[0] = rewrittenLine
        let rewritten = rewrittenLines.joined(separator: "\r\n")
        return HTTPProxyRequest(
            destination: ProxyDestination(host: host, port: port),
            isConnect: false,
            forwardData: Data(rewritten.utf8),
            leftover: Data()
        )
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

private struct NativeRouteMatcher {
    private let defaultOutbound: RuleAction
    private let entries: [Entry]
    private let requiredRuleSetTags: Set<String>
    private let ruleSetStore: RuleSetStore

    init(defaultOutbound: RuleAction, rules: [RoutingRule], ruleSetStore: RuleSetStore) {
        self.defaultOutbound = defaultOutbound
        self.entries = rules.flatMap { rule in
            rule.conditions.map { Entry(ruleName: rule.name, action: rule.type, condition: $0) }
        }
        self.requiredRuleSetTags = Set(entries.compactMap { entry -> String? in
            entry.condition.field == .ruleSet ? entry.condition.value : nil
        })
        self.ruleSetStore = ruleSetStore
    }

    func decision(for destination: ProxyDestination) -> RouteDecision {
        for entry in entries where matches(entry.condition, destination: destination) {
            return RouteDecision(action: entry.action, reason: "rule: \(entry.ruleName)")
        }
        if !ruleSetStore.allLoaded(tags: requiredRuleSetTags) {
            return RouteDecision(action: defaultOutbound, reason: "default; rule sets loading")
        }
        return RouteDecision(action: defaultOutbound, reason: "default")
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

    private func matches(_ condition: RuleCondition, destination: ProxyDestination) -> Bool {
        let host = destination.normalizedHost
        switch condition.field {
        case .domain:
            return host == condition.value.lowercased()
        case .domainSuffix:
            let suffix = condition.value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == suffix || host.hasSuffix(".\(suffix)")
        case .domainKeyword:
            return host.contains(condition.value.lowercased())
        case .ipCidr:
            guard let ip = IPAddress(host), let cidr = IPCIDR(condition.value) else { return false }
            return cidr.contains(ip)
        case .ruleSet:
            return ruleSetStore.matcher(for: condition.value)?.matches(destination: destination) == true
        }
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

    var logAction: String {
        action.rawValue.uppercased()
    }
}

private final class RuleSetStore {
    private let cacheDirectory: URL
    private let logger: (String, Bool) -> Void
    private var matchers: [String: RuleSetMatcher] = [:]
    private var loadingTags = Set<String>()
    private var failedTags = Set<String>()
    private let lock = NSLock()

    init(cacheDirectory: URL, logger: @escaping (String, Bool) -> Void) {
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

    func loadInBackground(tag: String, completion: @escaping () -> Void = {}) {
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

    func matches(destination: ProxyDestination) -> Bool {
        let host = destination.normalizedHost
        let ip = IPAddress(host)
        var result = false

        if !result {
            result = domainMatchers.contains { $0.matches(host) }
        }
        if !result {
            result = keywords.contains { host.contains($0) }
        }
        if !result, let ip {
            result = cidrs.contains { $0.contains(ip) }
        }
        if !subRules.isEmpty {
            switch mode {
            case .or:
                result = result || subRules.contains { $0.matches(destination: destination) }
            case .and:
                result = result || subRules.allSatisfy { $0.matches(destination: destination) }
            }
        }
        return invert ? !result : result
    }
}

private struct IPAddress: Comparable {
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

private struct IPCIDR {
    let network: IPAddress
    let bits: Int
    let rangeEnd: IPAddress?

    init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = IPAddress(parts[0]) else { return nil }
        let maxBits = address.bytes.count * 8
        let prefix = parts.count == 2 ? Int(parts[1]) : maxBits
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

    func matches(_ key: [UInt8]) -> Bool {
        guard !labelBitmap.isEmpty else { return false }
        let onePositions = labelBitmap.indicesAsBits(where: { $0 })

        func startIndex(for nodeId: Int) -> Int {
            guard nodeId == 0 || nodeId - 1 < onePositions.count else { return labelBitmap.count * 64 }
            return nodeId == 0 ? 0 : onePositions[nodeId - 1] + 1
        }

        func countZeros(upTo bitIndex: Int) -> Int {
            var zeros = 0
            for idx in 0..<bitIndex where !labelBitmap.bit(at: idx) {
                zeros += 1
            }
            return zeros
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
        let onePositions = labelBitmap.indicesAsBits(where: { $0 })
        func startIndex(for nodeId: Int) -> Int {
            nodeId == 0 ? 0 : onePositions[nodeId - 1] + 1
        }
        func countZeros(upTo bitIndex: Int) -> Int {
            var zeros = 0
            for idx in 0..<bitIndex where !labelBitmap.bit(at: idx) {
                zeros += 1
            }
            return zeros
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

private extension IPAddress {
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

private extension Array where Element == UInt64 {
    func bit(at index: Int) -> Bool {
        guard index >= 0, index >> 6 < count else { return true }
        return (self[index >> 6] & (UInt64(1) << UInt64(index & 63))) != 0
    }

    func indicesAsBits(where predicate: (Bool) -> Bool) -> [Int] {
        var output: [Int] = []
        for index in 0..<(count * 64) where predicate(bit(at: index)) {
            output.append(index)
        }
        return output
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
