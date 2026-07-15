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
        let staleUntil: Date
        var lastAccess: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLock = NSLock()
    private let minimumCacheTTL: TimeInterval = 30
    private let maximumCacheTTL: TimeInterval = 3_600
    /// 正缓存过期后仍可短期使用，并在后台刷新。DoH 临时抖动时不会立刻退回冷缓存路径。
    private let staleCacheTTL: TimeInterval = 3_600
    private let maximumCacheEntries = 2_048
    /// DoH 失败也短暂缓存，避免每个新连接都重复发起两个注定失败的查询。
    private let negativeCacheTTL: TimeInterval = 15

    /// in-flight 去重：同 host 并发 resolve 时，只发一次 DoH，其余等结果。
    /// 用引用类型 InFlightQuery 承载状态——leader 写入结果，follower 等待后读取，
    /// 避免 leader/follower 判定歧义（之前用 DispatchGroup 引用相等比较是错的）。
    private final class InFlightQuery: @unchecked Sendable {
        private struct State {
            var result: [String] = []
            var isDone = false
        }

        let group = DispatchGroup()
        let generation: UInt64
        private let state = LockedBox(State())

        init(generation: UInt64) {
            self.generation = generation
            group.enter()
        }

        /// 仅允许完成一次：clearCache 取消后，迟到的网络回调不会重复 leave。
        func complete(with result: [String]) {
            let shouldLeave = state.withLock { state -> Bool in
                guard !state.isDone else { return false }
                state.result = result
                state.isDone = true
                return true
            }
            if shouldLeave {
                group.leave()
            }
        }

        func completedResult() -> [String]? {
            state.withLock { $0.isDone ? $0.result : nil }
        }
    }
    private var inFlight: [String: InFlightQuery] = [:]
    private let inFlightLock = NSLock()

    private struct RuntimeState {
        var configuration = Configuration()
        var generation: UInt64 = 0
        var session: URLSession?
    }

    /// 配置、代次和 session 必须作为一个原子快照读写，避免查询混用新配置和旧 session。
    private let runtime = LockedBox(RuntimeState())

    private init() {}

    var isEnabled: Bool {
        runtime.withLock { $0.configuration.enabled && $0.configuration.url != nil }
    }

    func configure(_ newConfiguration: Configuration) {
        let newSession = newConfiguration.enabled ? makeProxiedSession(configuration: newConfiguration) : nil
        let transition = runtime.withLock { state -> (oldSession: URLSession?, shouldClearCache: Bool) in
            let oldConfiguration = state.configuration
            let shouldClearCache = oldConfiguration.enabled != newConfiguration.enabled
                || oldConfiguration.url != newConfiguration.url
            let oldSession = state.session
            state.configuration = newConfiguration
            state.generation &+= 1
            state.session = newSession
            return (oldSession, shouldClearCache)
        }
        transition.oldSession?.invalidateAndCancel()

        // 同一 DoH 服务商重连时保留仍在 TTL 内的结果，可避免重连后首页再次冷启动。
        // 但所有在途查询都属于旧 session，必须取消并唤醒等待者。
        cancelInFlightQueries()
        if transition.shouldClearCache {
            clearCachedResults()
        }
    }

    /// 解析域名。同步调用（在路由判定线程）。
    func resolve(_ host: String) -> [String] {
        let host = Self.canonicalHost(host)
        guard !host.isEmpty else { return [] }
        // 已是 IP 字面量，无需解析。
        if Self.isIPAddress(host) {
            return [host]
        }

        // 缓存命中。
        if let cached = cachedEntry(for: host), !cached.isStale {
            return cached.ips
        }

        // in-flight 去重：第一个调用成为 leader 执行查询，并发调用成为 follower 等待。
        let query: InFlightQuery
        var isLeader = false
        inFlightLock.lock()
        if let existing = inFlight[host] {
            query = existing
        } else {
            let generation = runtime.withLock { $0.generation }
            let newQuery = InFlightQuery(generation: generation)
            inFlight[host] = newQuery
            query = newQuery
            isLeader = true
        }
        inFlightLock.unlock()

        if !isLeader {
            // follower：等待 leader 完成，复用结果。
            query.group.wait()
            return query.completedResult() ?? []
        }

        // leader：执行 DoH，写入结果，通知所有 follower。
        let outcome = queryDoH(host: host, generation: query.generation)
        return finish(host: host, query: query, outcome: outcome)
    }

    /// 非阻塞解析：只返回缓存或已完成的 in-flight 结果，否则触发后台预解析并返回空数组。
    /// 给路由判定热路径用——连接不再因等 DoH 而卡住。代价是首次访问某域名时 IP 类
    /// 规则（geoip-cn 等）暂不生效，按域名规则/默认 outbound 处理；DoH 完成后缓存
    /// 生效，后续连接即可命中 IP 规则。对浏览场景，同一站点的后续请求很快复用缓存。
    func resolveCached(_ host: String) -> [String] {
        let host = Self.canonicalHost(host)
        guard !host.isEmpty else { return [] }
        if Self.isIPAddress(host) {
            return [host]
        }
        if let cached = cachedEntry(for: host) {
            if cached.isStale {
                prefetch(host)
            }
            return cached.ips
        }
        // in-flight 已有结果（leader 已完成）也能命中；否则不阻塞，直接预解析。
        if let query = lookupInFlight(host) {
            if let result = query.completedResult() {
                return result
            }
        }
        prefetch(host)
        return []
    }

    /// 异步预解析：在后台发起 DoH，填充缓存。复用 in-flight 去重，同 host 多次调用
    /// 只发一次查询。已缓存或已有 in-flight 时直接返回。
    func prefetch(_ host: String) {
        let host = Self.canonicalHost(host)
        guard !host.isEmpty else { return }
        if Self.isIPAddress(host) { return }
        if let cached = cachedEntry(for: host), !cached.isStale { return }

        let generation = runtime.withLock { $0.generation }
        var query: InFlightQuery?
        inFlightLock.lock()
        if inFlight[host] == nil {
            let newQuery = InFlightQuery(generation: generation)
            inFlight[host] = newQuery
            query = newQuery
        }
        inFlightLock.unlock()
        guard let query else { return }

        DispatchQueue.global(qos: .utility).async { [weak self, query] in
            guard let self else { return }
            let outcome = self.queryDoH(host: host, generation: query.generation)
            _ = self.finish(host: host, query: query, outcome: outcome)
        }
    }

    private func lookupInFlight(_ host: String) -> InFlightQuery? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[host]
    }

    func clearCache() {
        // 使已经越过 in-flight 身份检查的旧查询也无法在 clear 之后重新写入结果。
        runtime.withLock { $0.generation &+= 1 }
        clearCachedResults()
        cancelInFlightQueries()
    }

    private func clearCachedResults() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private func cancelInFlightQueries() {
        inFlightLock.lock()
        let cancelled = Array(inFlight.values)
        inFlight.removeAll()
        inFlightLock.unlock()
        cancelled.forEach { $0.complete(with: []) }
    }

    /// 仅当字典中仍是同一个 query 且配置代次未变时，才允许写缓存。
    /// 这防止断开/重连前的迟到回调移除新任务或污染新配置的缓存。
    @discardableResult
    private func finish(host: String, query: InFlightQuery, outcome: QueryOutcome) -> [String] {
        var finalIPs = outcome.ips
        inFlightLock.lock()
        let isCurrent = inFlight[host] === query
        if isCurrent {
            // 代次检查和缓存写入放在同一个 runtime 临界区：configure/clearCache
            // 要么发生在写入前、使其失效，要么发生在写入后并负责清掉旧缓存。
            runtime.withLock { state in
                guard state.generation == query.generation else {
                    finalIPs = query.completedResult() ?? []
                    return
                }
                if outcome.isValidResponse {
                    storeCache(host: host, ips: outcome.ips, ttl: outcome.ttl)
                } else if let stale = cachedEntry(for: host, staleOnly: true) {
                    // Xray 的 serve-stale 思路：刷新失败时保留最后一次可信结果。
                    finalIPs = stale.ips
                } else {
                    // 传输失败也短暂负缓存，避免每个连接都重复触发两个失败请求。
                    storeCache(host: host, ips: [], ttl: negativeCacheTTL)
                }
            }
            inFlight.removeValue(forKey: host)
        } else {
            // 已被 configure/clearCache 取消，或字典中已是更新的查询。
            finalIPs = query.completedResult() ?? []
        }
        inFlightLock.unlock()
        query.complete(with: finalIPs)
        return finalIPs
    }

    /// 判断字符串是否是合法 IPv4/IPv6 字面量。用 inet_pton，与项目其他地方一致。
    static func isIPAddress(_ string: String) -> Bool {
        var addr4 = in_addr()
        var addr6 = in6_addr()
        return inet_pton(AF_INET, string, &addr4) == 1 || inet_pton(AF_INET6, string, &addr6) == 1
    }

    /// DNS 名称大小写不敏感，末尾根标签点也不影响语义。统一 key 可提升缓存和 singleflight 命中率。
    static func canonicalHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    // MARK: - 缓存

    private struct CacheLookup {
        let ips: [String]
        let isStale: Bool
    }

    private func cachedEntry(for host: String, staleOnly: Bool = false) -> CacheLookup? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        guard var entry = cache[host], entry.staleUntil > now else {
            cache.removeValue(forKey: host)
            return nil
        }
        let isStale = entry.expiresAt <= now
        guard !staleOnly || isStale else { return nil }
        entry.lastAccess = now
        cache[host] = entry
        return CacheLookup(ips: entry.ips, isStale: isStale)
    }

    private func storeCache(host: String, ips: [String], ttl: TimeInterval?) {
        cacheLock.lock()
        let now = Date()
        let effectiveTTL: TimeInterval
        if ips.isEmpty {
            effectiveTTL = negativeCacheTTL
        } else {
            effectiveTTL = min(max(ttl ?? 300, minimumCacheTTL), maximumCacheTTL)
        }
        let expiresAt = now.addingTimeInterval(effectiveTTL)
        cache[host] = CacheEntry(
            ips: ips,
            expiresAt: expiresAt,
            staleUntil: ips.isEmpty ? expiresAt : expiresAt.addingTimeInterval(staleCacheTTL),
            lastAccess: now
        )
        trimCacheIfNeeded(now: now)
        cacheLock.unlock()
    }

    /// 防止长时间运行、访问大量随机子域名时缓存无限增长。优先清过期项，再按 LRU 淘汰。
    private func trimCacheIfNeeded(now: Date) {
        guard cache.count > maximumCacheEntries else { return }
        cache = cache.filter { $0.value.staleUntil > now }
        guard cache.count > maximumCacheEntries else { return }
        let overflow = cache.count - maximumCacheEntries
        for key in cache.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }).prefix(overflow).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }

    // MARK: - DoH 查询

    /// 并行查 A + AAAA，把总延迟从 2*timeout 降到 timeout。
    /// 复用同一 session 以共享代理连接。
    /// 用线程安全的 AtomicArray 收集结果，避免两个线程直接写捕获变量导致数据竞争。
    private struct QueryOutcome {
        let ips: [String]
        let ttl: TimeInterval?
        let isValidResponse: Bool

        static let failure = QueryOutcome(ips: [], ttl: nil, isValidResponse: false)
    }

    private struct RecordQueryResult {
        let ips: [String]
        let ttl: TimeInterval?
        let isNameError: Bool
    }

    private func queryDoH(host: String, generation: UInt64) -> QueryOutcome {
        let snapshot = runtime.withLock { state -> (Configuration, URLSession?)? in
            guard state.generation == generation else { return nil }
            return (state.configuration, state.session)
        }
        guard let (current, session) = snapshot,
              current.enabled,
              let dohURL = current.url,
              let session else { return .failure }

        // 线程安全的结果收集器。@unchecked Sendable：用 NSLock 保护，可跨线程安全访问。
        final class AtomicCollector: @unchecked Sendable {
            private var items: [RecordQueryResult] = []
            private let lock = NSLock()
            func append(_ x: RecordQueryResult?) {
                guard let x else { return }
                lock.lock(); items.append(x); lock.unlock()
            }
            func snapshot() -> [RecordQueryResult] {
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
                )
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
                )
            )
            group.leave()
        }
        // group.wait 受 timeout 约束（queryRecord 内部 URLSession 有超时）。
        _ = group.wait(timeout: .now() + current.timeout + 1)

        let responses = collector.snapshot()
        let isNameError = responses.contains(where: \.isNameError)
        // NXDOMAIN 对整个域名成立；若两个并发地址族返回矛盾结果，采用否定答案而不是缓存 IP。
        let ips = isNameError ? [] : Self.stableUnique(responses.flatMap(\.ips))
        let ttl = responses.compactMap(\.ttl).min()
        // 两个地址族均有合法响应、任一族拿到地址，或任一响应明确 NXDOMAIN，才可写可信缓存。
        let isValid = !ips.isEmpty || isNameError || responses.count == 2
        return QueryOutcome(ips: ips, ttl: ttl, isValidResponse: isValid)
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func makeProxiedSession(configuration: Configuration) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout * 2
        // A/AAAA 共用同一条 HTTP/2 连接，避免冷启动时同时建两条 SOCKS+TLS 连接。
        config.httpMaximumConnectionsPerHost = 1
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
    ) -> RecordQueryResult? {
        guard let query = DNSMessage.query(host: host, qtype: qtype) else { return nil }
        let expectedID = (UInt16(query[0]) << 8) | UInt16(query[1])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<(data: Data?, response: URLResponse?, error: Error?)>((nil, nil, nil))

        let task = session.dataTask(with: request) { data, response, error in
            result.withLock { $0 = (data, response, error) }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }

        let response = result.withLock { $0 }
        guard let data = response.data,
              response.error == nil,
              let http = response.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let dnsResponse = DNSMessage.parseResponse(data, expectedID: expectedID),
              dnsResponse.responseCode == 0 || dnsResponse.responseCode == 3 else { return nil }
        let records = dnsResponse.records.filter { $0.qtype == qtype }
        return RecordQueryResult(
            ips: records.map(\.ip),
            ttl: records.map { TimeInterval($0.ttl) }.min(),
            isNameError: dnsResponse.responseCode == 3
        )
    }
}

// MARK: - DNS 报文编解码

/// 最小化的 DNS wire format 实现（RFC 1035）。仅够构造 A/AAAA 查询、解析 Answer 段。
enum DNSMessage {
    struct Record {
        let qtype: UInt16
        let ip: String
        let ttl: UInt32
    }

    struct Response {
        let responseCode: UInt8
        let records: [Record]
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
        guard let response = parseResponse(data), !response.records.isEmpty else { return nil }
        return response.records
    }

    /// 解析并验证 DNS 响应。expectedID 用于拒绝与请求不对应的响应。
    static func parseResponse(_ data: Data, expectedID: UInt16? = nil) -> Response? {
        guard data.count >= 12 else { return nil }
        let id = (UInt16(data[0]) << 8) | UInt16(data[1])
        guard expectedID == nil || expectedID == id else { return nil }
        let flags = (UInt16(data[2]) << 8) | UInt16(data[3])
        guard (flags & 0x8000) != 0 else { return nil } // QR 必须是响应
        guard (flags & 0x0200) == 0 else { return nil } // DoH 不应接受截断响应
        let responseCode = UInt8(flags & 0x000f)
        let qdcount = (UInt16(data[4]) << 8) | UInt16(data[5])
        let ancount = (UInt16(data[6]) << 8) | UInt16(data[7])

        // 跳过所有 Question 段，而不是假定永远恰好一条。
        var offset = 12
        for _ in 0..<qdcount {
            guard let next = skipName(data: data, offset: offset), next + 4 <= data.count else { return nil }
            offset = next + 4
        }

        var records: [Record] = []
        for _ in 0..<ancount {
            guard let next = skipName(data: data, offset: offset), next + 10 <= data.count else { return nil }
            offset = next
            let qtype = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            let qclass = (UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3])
            let ttl = (UInt32(data[offset + 4]) << 24)
                | (UInt32(data[offset + 5]) << 16)
                | (UInt32(data[offset + 6]) << 8)
                | UInt32(data[offset + 7])
            let rdlength = (UInt16(data[offset + 8]) << 8) | UInt16(data[offset + 9])
            offset += 10
            guard offset + Int(rdlength) <= data.count else { return nil }

            if qclass == 1, (qtype == 1 && rdlength == 4) || (qtype == 28 && rdlength == 16) {
                let rdata = data.subdata(in: offset..<offset + Int(rdlength))
                if let ip = formatIP(rdata: rdata) {
                    records.append(Record(qtype: qtype, ip: ip, ttl: ttl))
                }
            }
            offset += Int(rdlength)
        }
        return Response(responseCode: responseCode, records: records)
    }

    private static func skipName(data: Data, offset: Int) -> Int? {
        var i = offset
        while i < data.count {
            let len = data[i]
            if len == 0 { return i + 1 }
            if (len & 0xc0) == 0xc0 {
                return i + 1 < data.count ? i + 2 : nil
            }
            guard len <= 63, i + Int(len) < data.count else { return nil }
            i += Int(len) + 1
        }
        return nil
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
