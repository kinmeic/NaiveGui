import Darwin
import Foundation

/// UDP 包转发器：处理非 DNS 的 UDP 流量（QUIC、游戏、VPN 等）。
///
/// 工作流程：
/// 1. 从 utun 收到 UDP 包 → 解析 (src, dst, payload)
/// 2. 路由判定：matcher.decision((dst.host, dst.port))
/// 3. proxy：经本地 naive SOCKS5 转发（SOCKS5 UDP ASSOCIATE）
///    direct：直接 sendto 目标
///    block：丢弃
/// 4. 反向流量用 NAT 表映射回 utun
///
/// 线程安全：NAT 表用 LockedBox 保护。
final class UdpRelay {
    private let matcher: NativeRouteMatcher
    private let naivePort: Int

    /// NAT 表：映射 (本地临时端口 → 目标地址)，用于反向流量路由。
    private let natTable = LockedBox<[UInt16: NatEntry]>([:])
    private var nextEphemeralPort: UInt16 = 50000

    struct NatEntry {
        let dstHost: String
        let dstPort: UInt16
        let srcIP: String       // 原始 utun 侧源 IP
        let srcPort: UInt16     // 原始 utun 侧源端口
    }

    init(matcher: NativeRouteMatcher, naivePort: Int) {
        self.matcher = matcher
        self.naivePort = naivePort
    }

    /// 处理一个 UDP 包。返回需要注入 utun 的响应包，nil 表示丢弃。
    func handle(packet: Data) -> Data? {
        guard let (srcIP, dstIP, srcPort, dstPort, payload) = parseUdpPacket(packet) else {
            return nil
        }
        guard dstPort != 53 else { return nil }  // DNS 由 DnsInterceptor 处理

        let destination = ProxyDestination(host: dstIP, port: Int(dstPort))
        let decision = matcher.decision(for: destination)

        switch decision.action {
        case .block:
            return nil
        case .direct:
            return handleDirect(srcIP: srcIP, dstIP: dstIP, srcPort: srcPort, dstPort: dstPort, payload: payload)
        case .proxy:
            return handleProxy(srcIP: srcIP, dstIP: dstIP, srcPort: srcPort, dstPort: dstPort, payload: payload, decision: decision)
        }
    }

    // MARK: - Direct UDP

    private func handleDirect(srcIP: String, dstIP: String, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data? {
        // 直接 sendto 目标，接收响应后构造 IP+UDP 包注入 utun。
        // 注意：这是同步调用，会阻塞 poll 线程。阶段 1 MVP 用同步；
        // 后续可改为异步（DispatchQueue + 回调注入）。
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(dstIP, "\(dstPort)", &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(first) }

        let fd = socket(first.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // 发送
        _ = payload.withUnsafeBytes { buf in
            sendto(fd, buf.baseAddress, payload.count, 0, first.pointee.ai_addr, first.pointee.ai_addrlen)
        }

        // 接收响应（带超时）
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var responseBuf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(fd, &responseBuf, responseBuf.count, 0)
        guard n > 0 else { return nil }
        let responsePayload = Data(responseBuf.prefix(n))

        // 构造响应 IP+UDP 包
        return buildUdpResponse(
            srcIP: dstIP,        // 响应来自目标
            dstIP: srcIP,        // 回到原始源
            srcPort: dstPort,    // 响应来自目标端口
            dstPort: srcPort,    // 回到原始源端口
            payload: responsePayload
        )
    }

    // MARK: - Proxy UDP

    private func handleProxy(srcIP: String, dstIP: String, srcPort: UInt16, dstPort: UInt16,
                             payload: Data, decision: RouteDecision) -> Data? {
        // SOCKS5 UDP ASSOCIATE：经本地 naive 转发。
        // 1. 建立 TCP 控制连接到 naive SOCKS5
        // 2. 发 UDP ASSOCIATE 请求，拿到 UDP 中继地址
        // 3. 向中继地址发 SOCKS5 UDP 封装包
        // 4. 接收响应，解封装
        //
        // 阶段 1 MVP：简化为同步实现。naive 需支持 UDP（不是所有节点都支持）。
        // 失败时返回 nil（丢弃），应用会回退到 TCP。
        guard let connectHost = decision.resolvedIP ?? dstIP else { return nil }

        // 1. TCP 控制连接
        let ctrlFd = socket(AF_INET, SOCK_STREAM, 0)
        guard ctrlFd >= 0 else { return nil }
        defer { close(ctrlFd) }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "\(naivePort)", &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(first) }
        guard Darwin.connect(ctrlFd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { return nil }

        // 2. SOCKS5 握手 + UDP ASSOCIATE
        let handshake: [UInt8] = [0x05, 0x01, 0x00]
        _ = send(ctrlFd, handshake, handshake.count, 0)
        var resp = [UInt8](repeating: 0, count: 2)
        guard recv(ctrlFd, &resp, 2, 0) == 2, resp == [0x05, 0x00] else { return nil }

        // UDP ASSOCIATE（CMD=3）
        var associateReq = Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        _ = associateReq.withUnsafeBytes { send(ctrlFd, $0.baseAddress, associateReq.count, 0) }
        var associateResp = [UInt8](repeating: 0, count: 10)
        guard recv(ctrlFd, &associateResp, 10, 0) == 10, associateResp[1] == 0x00 else { return nil }

        let relayPort = (UInt16(associateResp[8]) << 8) | UInt16(associateResp[9])
        guard relayPort > 0 else { return nil }

        // 3. 向中继发 SOCKS5 UDP 封装包
        let udpFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpFd >= 0 else { return nil }
        defer { close(udpFd) }

        var relayHints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                                  ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                                  ai_addr: nil, ai_next: nil)
        var relayResult: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "\(relayPort)", &relayHints, &relayResult) == 0,
              let relayAddr = relayResult else { return nil }
        defer { freeaddrinfo(relayAddr) }

        // SOCKS5 UDP 封装：RSV(2) + FRAG(1) + ATYP(1) + DST.ADDR + DST.PORT + DATA
        var socksUdp = Data([0x00, 0x00, 0x00])  // RSV + FRAG
        // ATYP + 地址
        if let ipv4 = IPv4Address(connectHost) {
            socksUdp.append(0x01)
            socksUdp.append(ipv4.rawValue)
        } else {
            let bytes = Array(connectHost.utf8)
            socksUdp.append(0x03)
            socksUdp.append(UInt8(min(bytes.count, 255)))
            socksUdp.append(contentsOf: bytes.prefix(255))
        }
        socksUdp.append(UInt8(dstPort >> 8))
        socksUdp.append(UInt8(dstPort & 0xff))
        socksUdp.append(payload)

        _ = socksUdp.withUnsafeBytes { buf in
            sendto(udpFd, buf.baseAddress, socksUdp.count, 0, relayAddr.pointee.ai_addr, relayAddr.pointee.ai_addrlen)
        }

        // 4. 接收响应
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(udpFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var responseBuf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(udpFd, &responseBuf, responseBuf.count, 0)
        guard n > 10 else { return nil }  // 至少有 SOCKS5 头

        // 解封装：跳过 RSV(2) + FRAG(1) + ATYP(1) + 地址 + 端口(2)
        let atyp = responseBuf[3]
        var headerLen = 0
        switch atyp {
        case 0x01: headerLen = 4 + 4 + 2  // ATYP + IPv4 + port
        case 0x03: headerLen = 4 + 1 + Int(responseBuf[4]) + 2  // ATYP + len + domain + port
        case 0x04: headerLen = 4 + 16 + 2  // ATYP + IPv6 + port
        default: return nil
        }
        guard n > headerLen else { return nil }
        let responsePayload = Data(responseBuf[headerLen..<n])

        return buildUdpResponse(
            srcIP: dstIP,
            dstIP: srcIP,
            srcPort: dstPort,
            dstPort: srcPort,
            payload: responsePayload
        )
    }

    // MARK: - IP+UDP 包解析/构造

    private func parseUdpPacket(_ data: Data) -> (String, String, UInt16, UInt16, Data)? {
        guard data.count >= 28 else { return nil }
        let version = data[0] >> 4
        guard version == 4 else { return nil }

        let ihl = Int(data[0] & 0x0f) * 4
        guard ihl >= 20, data.count >= ihl + 8 else { return nil }
        guard data[9] == 17 else { return nil }  // UDP

        let srcIP = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let dstIP = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"
        let srcPort = (UInt16(data[ihl]) << 8) | UInt16(data[ihl + 1])
        let dstPort = (UInt16(data[ihl + 2]) << 8) | UInt16(data[ihl + 3])
        let payload = data.subdata(in: (ihl + 8)..<data.count)
        return (srcIP, dstIP, srcPort, dstPort, payload)
    }

    private func buildUdpResponse(srcIP: String, dstIP: String, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        var packet = Data()
        let totalLength = UInt16(20 + 8 + payload.count)
        packet.append(contentsOf: [0x45, 0x00])
        packet.append(UInt8(totalLength >> 8)); packet.append(UInt8(totalLength & 0xff))
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00])
        for part in srcIP.split(separator: ".") { packet.append(UInt8(String(part)) ?? 0) }
        for part in dstIP.split(separator: ".") { packet.append(UInt8(String(part)) ?? 0) }
        packet.append(UInt8(srcPort >> 8)); packet.append(UInt8(srcPort & 0xff))
        packet.append(UInt8(dstPort >> 8)); packet.append(UInt8(dstPort & 0xff))
        let udpLength = UInt16(8 + payload.count)
        packet.append(UInt8(udpLength >> 8)); packet.append(UInt8(udpLength & 0xff))
        packet.append(contentsOf: [0x00, 0x00])
        packet.append(payload)
        return packet
    }
}
