import Foundation
import NetworkExtension

/// 隧道引擎：从 utun 读包 → 分类（TCP/UDP/DNS）→ 转发 → 响应注入 utun。
///
/// 借鉴 RelayHub 的单线程 poll 循环模式，但这里用 NEPacketTunnelFlow 的
/// readPackets 回调（系统管理的异步读取，无需自己 poll）。
///
/// 阶段 2：TCP 由 TcpReassembler 重组，提取的字节流经路由引擎判定后
/// 连接上游（naive/direct），上游响应通过 reassembler.writeData 注入回 utun。
final class TunnelEngine {
    private let packetFlow: NEPacketTunnelFlow
    private let dnsInterceptor: DnsInterceptor
    private let udpRelay: UdpRelay
    private let tcpReassembler: TcpReassembler
    private let matcher: NativeRouteMatcher
    private let naivePort: Int
    private var isRunning = false

    /// 活跃 TCP 上游连接：连接 key → 上游 socket fd。
    private var tcpUpstreams: [String: Int32] = [:]
    private let upstreamLock = NSLock()

    init(packetFlow: NEPacketTunnelFlow,
         dnsInterceptor: DnsInterceptor,
         udpRelay: UdpRelay,
         tcpReassembler: TcpReassembler,
         matcher: NativeRouteMatcher,
         naivePort: Int) {
        self.packetFlow = packetFlow
        self.dnsInterceptor = dnsInterceptor
        self.udpRelay = udpRelay
        self.tcpReassembler = tcpReassembler
        self.matcher = matcher
        self.naivePort = naivePort

        // TCP 重组回调
        tcpReassembler.onData = { [weak self] host, port, data in
            self?.handleTcpData(host: host, port: port, data: data)
        }
        tcpReassembler.onConnect = { _, _ in
            // 连接建立时可初始化上游
        }
        tcpReassembler.onDisconnect = { [weak self] host, port in
            self?.closeTcpUpstream(host: host, port: port)
        }
    }

    func start() {
        isRunning = true
        readPackets()
    }

    func stop() {
        isRunning = false
        // 关闭所有上游连接
        upstreamLock.lock()
        for (_, fd) in tcpUpstreams {
            close(fd)
        }
        tcpUpstreams.removeAll()
        upstreamLock.unlock()
        tcpReassembler.reset()
    }

    // MARK: - 包读取循环

    private func readPackets() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning else { return }
            self.handlePackets(packets, protocols: protocols)
            // 刷新 TCP 重组器的输出包（ACK 等）到 utun
            self.flushTcpOutput()
            self.readPackets()
        }
    }

    private func flushTcpOutput() {
        let packets = tcpReassembler.flushOutputPackets()
        if !packets.isEmpty {
            packetFlow.writePackets(packets, withProtocols: [NSNumber](repeating: NSNumber(value: AF_INET), count: packets.count))
        }
    }

    // MARK: - 包分类

    private func handlePackets(_ packets: [Data], protocols: [NSNumber]) {
        for (index, packet) in packets.enumerated() {
            guard index < protocols.count else { continue }
            let protoFamily = protocols[index].int32Value
            guard protoFamily == AF_INET else { continue }
            guard packet.count >= 20 else { continue }
            let ipProtocol = packet[9]

            switch ipProtocol {
            case 6:   // TCP
                tcpReassembler.input(packet)
            case 17:  // UDP
                handleUdp(packet)
            default:
                continue
            }
        }
    }

    // MARK: - UDP 处理

    private func handleUdp(_ packet: Data) {
        if isDnsQuery(packet) {
            if let response = dnsInterceptor.handle(queryPacket: packet) {
                packetFlow.writePackets([response], withProtocols: [NSNumber(value: AF_INET)])
            }
        } else {
            if let response = udpRelay.handle(packet: packet) {
                packetFlow.writePackets([response], withProtocols: [NSNumber(value: AF_INET)])
            }
        }
    }

    private func isDnsQuery(_ packet: Data) -> Bool {
        guard packet.count >= 28 else { return false }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return false }
        guard packet[9] == 17 else { return false }
        let dstPort = (UInt16(packet[ihl + 2]) << 8) | UInt16(packet[ihl + 3])
        return dstPort == 53
    }

    // MARK: - TCP 数据处理

    /// 收到 TCP 字节流（从 reassembler）→ 路由判定 → 连接上游 → 转发。
    /// 上游响应通过 reassembler.writeData 注入回 utun。
    private func handleTcpData(host: String, port: UInt16, data: Data) {
        let destination = ProxyDestination(host: host, port: Int(port))
        let decision = matcher.decision(for: destination)

        switch decision.action {
        case .block:
            return  // 丢弃
        case .direct, .proxy:
            // 首次数据：建立上游连接（直连或经 naive SOCKS5）
            let key = "\(host):\(port)"
            upstreamLock.lock()
            var fd = tcpUpstreams[key]
            upstreamLock.unlock()

            if fd == nil {
                let connectHost = decision.resolvedIP ?? host
                let connectPort = port
                if decision.action == .proxy {
                    fd = connectViaNaive(host: connectHost, port: connectPort)
                } else {
                    fd = connectDirect(host: connectHost, port: connectPort)
                }
                if let fd, fd >= 0 {
                    upstreamLock.lock()
                    tcpUpstreams[key] = fd
                    upstreamLock.unlock()
                    // 启动后台线程读上游响应
                    startUpstreamReader(fd: fd, key: key, host: host, port: port)
                } else {
                    return  // 连接失败，丢弃数据
                }
            }

            // 转发数据到上游
            if let fd, fd >= 0 {
                _ = data.withUnsafeBytes { buf in
                    send(fd, buf.baseAddress, data.count, 0)
                }
            }
        }
    }

    // MARK: - 上游连接

    private func connectDirect(host: String, port: UInt16) -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &result) == 0, let first = result else { return -1 }
        defer { freeaddrinfo(first) }
        let fd = socket(first.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        // 设非阻塞 + poll 超时
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if r == 0 || errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 10_000) > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0 {
                    _ = fcntl(fd, F_SETFL, flags)  // 恢复阻塞
                    return fd
                }
            }
        }
        close(fd)
        return -1
    }

    private func connectViaNaive(host: String, port: UInt16) -> Int32 {
        // 复用 NativeRoutingProxyManager 的 SOCKS5 客户端逻辑
        let dest = ProxyDestination(host: host, port: Int(port))
        do {
            // 通过 SOCKS5.connectViaProxy 连本地 naive
            let fd = try SOCKS5.connectViaProxy(
                proxyHost: "127.0.0.1", proxyPort: naivePort, destination: dest
            )
            return fd
        } catch {
            return -1
        }
    }

    // MARK: - 上游响应读取

    /// 后台线程读上游响应，注入回 TCP 重组器 → utun。
    private func startUpstreamReader(fd: Int32, key: String, host: String, port: UInt16) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                let data = Data(buffer.prefix(n))
                self?.tcpReassembler.writeData(data, toHost: host, port: port)
                // 刷新输出到 utun
                let packets = self?.tcpReassembler.flushOutputPackets() ?? []
                if !packets.isEmpty {
                    self?.packetFlow.writePackets(packets, withProtocols: [NSNumber](repeating: NSNumber(value: AF_INET), count: packets.count))
                }
            }
            self?.closeTcpUpstream(key: key)
        }
    }

    private func closeTcpUpstream(host: String, port: UInt16) {
        closeTcpUpstream(key: "\(host):\(port)")
    }

    private func closeTcpUpstream(key: String) {
        upstreamLock.lock()
        let fd = tcpUpstreams.removeValue(forKey: key)
        upstreamLock.unlock()
        if let fd {
            close(fd)
        }
    }
}
