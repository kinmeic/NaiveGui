import Darwin
import Foundation
import Network

/// DoH (DNS over HTTPS) 解析器。
///
/// 职责：把域名解析成 IP，DoH 请求本身经本地 naive SOCKS5 代理发出，避免 DNS 泄漏。
/// 解析出的 IP 用于匹配 IP 类路由规则（ipCidr、geoip-*），让原本对域名流量失效的
/// GeoIP 规则重新生效。
///
/// 失败回退策略：DoH 不可用时返回空数组，调用方（路由引擎）将跳过 IP 规则，
/// 仅用域名规则 + default outbound 判定，不影响连通性。
final class DNSResolver: @unchecked Sendable {
    static let shared = DNSResolver()

    struct Configuration: Sendable {
        var enabled = false
        var url: URL?
        var socksProxyHost = "127.0.0.1"
        var socksProxyPort = 1080
        var timeout: TimeInterval = 5
    }

    /// DoH 服务商预设。
    enum Provider: String, CaseIterable {
        case google
        case cloudflare
        case quad9

        var url: URL {
            switch self {
            case .google: return URL(string: "https://dns.google/dns-query")!
            case .cloudflare: return URL(string: "https://cloudflare-dns.com/dns-query")!
            case .quad9: return URL(string: "https://dns.quad9.net/dns-query")!
            }
        }

        var displayName: String {
            switch self {
            case .google: return "Google (8.8.8.8)"
            case .cloudflare: return "Cloudflare (1.1.1.1)"
            case .quad9: return "Quad9 (9.9.9.9)"
            }
        }
    }

    /// 解析结果缓存项。值类型。
    private struct CacheEntry {
        let ips: [String]
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLock = NSLock()
    private let cacheTTL: TimeInterval = 300

    /// in-flight 去重：同 host 并发 resolve 时，只发一次 DoH，其余等结果。
    /// 用引用类型 InFlightQuery 承载状态——leader 写入结果，follower 等待后读取，
    /// 避免 leader/follower 判定歧义（之前用 DispatchGroup 引用相等比较是错的）。
    private final class InFlightQuery: @unchecked Sendable {
        let group = DispatchGroup()
        let result = LockedBox<[String]>([])
        /// leader 完成后置 true，让 resolveCached 能区分"尚在查询"与"已完成但结果为空"。
        let isDone = LockedBox<Bool>(false)
        init() { group.enter() }
    }
    private var inFlight: [String: InFlightQuery] = [:]
    private let inFlightLock = NSLock()

    private let configuration = LockedBox(Configuration())

    /// 持久化复用的 DoH URLSession。避免每次 queryDoH 都新建 session + 新建一条
    /// 到代理的 SOCKS 连接——复用底层 TCP/TLS，单次查询延迟从"SOCKS握手+TLS+请求"
    /// 降到只剩请求本身。configure 时重建（端口/代理变化时丢弃旧连接）。
    private let sessionBox = LockedBox<URLSession?>(nil)

    private init() {}

    func configure(_ newConfiguration: Configuration) {
        configuration.withLock { $0 = newConfiguration }
        // 重建 session：代理端口/DoH URL 变化后旧连接不再适用。
        let old = sessionBox.withLock { $0 }
        old?.invalidateAndCancel()
        let newSession = newConfiguration.enabled ? makeProxiedSession(configuration: newConfiguration) : nil
        sessionBox.withLock { $0 = newSession }
        clearCache()
    }

    /// 解析域名。同步调用（在路由判定线程）。
    func resolve(_ host: String) -> [String] {
        // 已是 IP 字面量，无需解析。
        if Self.isIPAddress(host) {
            return [host]
        }

        // 缓存命中。
        if let cached = cachedEntry(for: host) {
            return cached
        }

        // in-flight 去重：第一个调用成为 leader 执行查询，并发调用成为 follower 等待。
        let query: InFlightQuery
        var isLeader = false
        inFlightLock.lock()
        if let existing = inFlight[host] {
            query = existing
        } else {
            let newQuery = InFlightQuery()
            inFlight[host] = newQuery
            query = newQuery
            isLeader = true
        }
        inFlightLock.unlock()

        if !isLeader {
            // follower：等待 leader 完成，复用结果。
            query.group.wait()
            return query.result.withLock { $0 }
        }

        // leader：执行 DoH，写入结果，通知所有 follower。
        let ips = queryDoH(host: host)
        if !ips.isEmpty {
            storeCache(host: host, ips: ips)
        }
        query.result.withLock { $0 = ips }
        query.isDone.withLock { $0 = true }
        inFlightLock.lock()
        inFlight.removeValue(forKey: host)
        inFlightLock.unlock()
        query.group.leave()
        return ips
    }

    /// 非阻塞解析：只返回缓存或已完成的 in-flight 结果，否则触发后台预解析并返回空数组。
    /// 给路由判定热路径用——连接不再因等 DoH 而卡住。代价是首次访问某域名时 IP 类
    /// 规则（geoip-cn 等）暂不生效，按域名规则/默认 outbound 处理；DoH 完成后缓存
    /// 生效，后续连接即可命中 IP 规则。对浏览场景，同一站点的后续请求很快复用缓存。
    func resolveCached(_ host: String) -> [String] {
        if Self.isIPAddress(host) {
            return [host]
        }
        if let cached = cachedEntry(for: host) {
            return cached
        }
        // in-flight 已有结果（leader 已完成）也能命中；否则不阻塞，直接预解析。
        if let query = lookupInFlight(host) {
            if query.isDone.withLock({ $0 }) {
                return query.result.withLock { $0 }
            }
        }
        prefetch(host)
        return []
    }

    /// 异步预解析：在后台发起 DoH，填充缓存。复用 in-flight 去重，同 host 多次调用
    /// 只发一次查询。已缓存或已有 in-flight 时直接返回。
    func prefetch(_ host: String) {
        if Self.isIPAddress(host) { return }
        if cachedEntry(for: host) != nil { return }

        var isLeader = false
        inFlightLock.lock()
        if inFlight[host] == nil {
            inFlight[host] = InFlightQuery()
            isLeader = true
        }
        inFlightLock.unlock()
        guard isLeader else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let ips = self.queryDoH(host: host)
            if !ips.isEmpty {
                self.storeCache(host: host, ips: ips)
            }
            self.inFlightLock.lock()
            let query = self.inFlight.removeValue(forKey: host)
            self.inFlightLock.unlock()
            query?.result.withLock { $0 = ips }
            query?.isDone.withLock { $0 = true }
            query?.group.leave()
        }
    }

    private func lookupInFlight(_ host: String) -> InFlightQuery? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[host]
    }

    func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
        inFlightLock.lock()
        inFlight.removeAll()
        inFlightLock.unlock()
    }

    /// 判断字符串是否是合法 IPv4/IPv6 字面量。用 inet_pton，与项目其他地方一致。
    static func isIPAddress(_ string: String) -> Bool {
        var addr4 = in_addr()
        var addr6 = in6_addr()
        return inet_pton(AF_INET, string, &addr4) == 1 || inet_pton(AF_INET6, string, &addr6) == 1
    }

    // MARK: - 缓存

    private func cachedEntry(for host: String) -> [String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[host], entry.expiresAt > Date() else {
            cache.removeValue(forKey: host) // 顺手清过期项
            return nil
        }
        return entry.ips
    }

    private func storeCache(host: String, ips: [String]) {
        cacheLock.lock()
        cache[host] = CacheEntry(ips: ips, expiresAt: Date().addingTimeInterval(cacheTTL))
        cacheLock.unlock()
    }

    // MARK: - DoH 查询

    /// 并行查 A + AAAA，把总延迟从 2*timeout 降到 timeout。
    /// 复用同一 session 以共享代理连接。
    /// 用线程安全的 AtomicArray 收集结果，避免两个线程直接写捕获变量导致数据竞争。
    private func queryDoH(host: String) -> [String] {
        let current = configuration.withLock { $0 }
        guard current.enabled, let dohURL = current.url else { return [] }

        // 复用持久化 session（configure 时创建）。失效时回退到临时 session，保证可用性。
        let session = sessionBox.withLock { $0 } ?? {
            let s = makeProxiedSession(configuration: current)
            sessionBox.withLock { $0 = s }
            return s
        }()

        // 线程安全的结果收集器。@unchecked Sendable：用 NSLock 保护，可跨线程安全访问。
        final class AtomicCollector: @unchecked Sendable {
            private var items: [String] = []
            private let lock = NSLock()
            func append(_ x: [String]) {
                lock.lock(); items.append(contentsOf: x); lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock(); defer { lock.unlock() }
                return items
            }
        }
        let collector = AtomicCollector()
        let group = DispatchGroup()
        // 捕获 self 到局部，避免 @Sendable 闭包直接捕获可变 self。
        let resolver = self

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            collector.append(
                resolver.queryRecord(
                    session: session,
                    url: dohURL,
                    host: host,
                    qtype: 1,
                    timeout: current.timeout
                ) ?? []
            )
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            collector.append(
                resolver.queryRecord(
                    session: session,
                    url: dohURL,
                    host: host,
                    qtype: 28,
                    timeout: current.timeout
                ) ?? []
            )
            group.leave()
        }
        // group.wait 受 timeout 约束（queryRecord 内部 URLSession 有超时）。
        _ = group.wait(timeout: .now() + current.timeout + 1)

        return collector.snapshot()
    }

    private func makeProxiedSession(configuration: Configuration) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout * 2
        // 关键：让 DoH 的 HTTPS 请求经本地 naive SOCKS5 代理出去，防止 DNS 泄漏。
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: configuration.socksProxyHost,
            kCFNetworkProxiesSOCKSPort as String: configuration.socksProxyPort
        ]
        return URLSession(configuration: config)
    }

    /// 单条 DNS 查询（同步）。qtype: 1=A, 28=AAAA。
    private func queryRecord(
        session: URLSession,
        url: URL,
        host: String,
        qtype: UInt16,
        timeout: TimeInterval
    ) -> [String]? {
        guard let query = DNSMessage.query(host: host, qtype: qtype) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<(data: Data?, error: Error?)>((nil, nil))

        let task = session.dataTask(with: request) { data, _, error in
            result.withLock { $0 = (data, error) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)

        let response = result.withLock { $0 }
        guard let data = response.data, response.error == nil else { return nil }
        return DNSMessage.parseAnswers(data)?.filter { $0.qtype == qtype }.map { $0.ip }
    }
}

// MARK: - DNS 报文编解码

/// 最小化的 DNS wire format 实现（RFC 1035）。仅够构造 A/AAAA 查询、解析 Answer 段。
enum DNSMessage {
    struct Record {
        let qtype: UInt16
        let ip: String
    }

    /// 构造查询报文。
    static func query(host: String, qtype: UInt16) -> Data? {
        var data = Data()
        // Header（12 字节）
        let id = UInt16.random(in: 1...UInt16.max)
        data.append(UInt8(id >> 8))
        data.append(UInt8(id & 0xff))
        // flags: 0x0100 = 递归查询 (RD=1)
        data.append(contentsOf: [0x01, 0x00])
        // QDCOUNT=1, ANCOUNT=NSCOUNT=ARCOUNT=0
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // QNAME：域名按 . 分段，每段前缀长度字节，以 0 结尾。
        let labels = host.split(separator: ".").map(String.init)
        for label in labels {
            guard let bytes = label.data(using: .ascii), bytes.count <= 63 else { return nil }
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        data.append(0x00)

        // QTYPE（2 字节）+ QCLASS=IN（2 字节）
        data.append(UInt8(qtype >> 8))
        data.append(UInt8(qtype & 0xff))
        data.append(contentsOf: [0x00, 0x01])
        return data
    }

    /// 解析响应里的 Answer 段，提取 A/AAAA 记录。
    static func parseAnswers(_ data: Data) -> [Record]? {
        guard data.count >= 12 else { return nil }
        let ancount = (UInt16(data[6]) << 8) | UInt16(data[7])
        guard ancount > 0 else { return nil }

        // 跳过 Header（12）+ Question 段。Question 段 = QNAME + 4 字节。
        var offset = 12
        // 跳过 QNAME（找到 0 终止符）。
        while offset < data.count {
            let len = data[offset]
            if len == 0 { offset += 1; break }
            // 压缩指针（高两 bit 为 11）在 QNAME 中不应出现，但防御性处理。
            if (len & 0xc0) == 0xc0 { offset += 2; break }
            offset += Int(len) + 1
        }
        offset += 4 // QTYPE + QCLASS

        var records: [Record] = []
        for _ in 0..<ancount {
            guard offset < data.count else { break }
            // NAME：可能是压缩指针，跳过即可。
            offset = skipName(data: data, offset: offset)
            guard offset + 10 <= data.count else { break }
            let qtype = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            let rdlength = (UInt16(data[offset + 8]) << 8) | UInt16(data[offset + 9])
            offset += 10
            guard offset + Int(rdlength) <= data.count else { break }

            if (qtype == 1 && rdlength == 4) || (qtype == 28 && rdlength == 16) {
                let rdata = data.subdata(in: offset..<offset + Int(rdlength))
                if let ip = formatIP(rdata: rdata) {
                    records.append(Record(qtype: qtype, ip: ip))
                }
            }
            offset += Int(rdlength)
        }
        return records
    }

    private static func skipName(data: Data, offset: Int) -> Int {
        var i = offset
        while i < data.count {
            let len = data[i]
            if len == 0 { return i + 1 }
            if (len & 0xc0) == 0xc0 { return i + 2 } // 压缩指针
            i += Int(len) + 1
        }
        return i
    }

    private static func formatIP(rdata: Data) -> String? {
        if rdata.count == 4 {
            return rdata.map(String.init).joined(separator: ".")
        }
        if rdata.count == 16 {
            // IPv6：转成标准冒号十六进制。
            let bytes = [UInt8](rdata)
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr.__u6_addr.__u6_addr8) { ptr in
                for i in 0..<16 { ptr[i] = bytes[i] }
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let result = withUnsafePointer(to: &addr) {
                inet_ntop(AF_INET6, $0, &buf, socklen_t(INET6_ADDRSTRLEN))
            }
            if result != nil {
                return String(cString: buf)
            }
            // fallback：手工格式化
            var parts: [String] = []
            for idx in stride(from: 0, to: bytes.count, by: 2) {
                parts.append(String(format: "%02x%02x", bytes[idx], bytes[idx + 1]))
            }
            return parts.joined(separator: ":")
        }
        return nil
    }
}
