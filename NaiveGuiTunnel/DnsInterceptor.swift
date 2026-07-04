import Darwin
import Foundation

/// DNS 劫持器：拦截 UDP 53 端口的 DNS 查询，改走 DoH 解析，构造 DNS 响应包注入 utun。
///
/// 工作流程：
/// 1. 从原始 IP+UDP 包中提取 DNS 查询
/// 2. 解析查询的域名和类型（A/AAAA）
/// 3. 调用 DNSResolver.resolve（走代理 DoH）
/// 4. 构造 DNS 响应包（IP+UDP+DNS），注入 utun 回给应用
///
/// 这样即使应用硬编码 8.8.8.8:53，也会被劫持到 DoH，彻底防 DNS 泄漏。
final class DnsInterceptor {
    private let resolver: DNSResolver
    private let dnsServerIP: String  // 虚拟 DNS 服务器 IP（utun 侧）

    init(resolver: DNSResolver, dnsServerIP: String = "198.18.0.2") {
        self.resolver = resolver
        self.dnsServerIP = dnsServerIP
    }

    /// 处理一个 DNS 查询包。返回构造好的 DNS 响应包（IP+UDP），nil 表示无法处理。
    func handle(queryPacket: Data) -> Data? {
        // 解析 IP 头 + UDP 头，提取 DNS payload。
        guard let (srcIP, dstIP, srcPort, dnsPayload) = parseDnsPacket(queryPacket) else {
            return nil
        }
        guard dstPort == 53 else { return nil }

        // 从 DNS payload 提取查询域名和类型。
        guard let (domain, qtype, transactionID) = parseDnsQuery(dnsPayload) else {
            return nil
        }

        // 已是 IP 字面量查询（如 PTR），跳过。
        if DNSResolver.isIPAddress(domain) {
            return nil
        }

        // 调 DoH 解析（走代理，防泄漏）。
        let resolvedIPs = resolver.resolve(domain)
        let answers = resolvedIPs.prefix(10)  // 限制响应大小

        // 构造 DNS 响应 payload。
        let responsePayload = buildDnsResponse(
            transactionID: transactionID,
            domain: domain,
            qtype: qtype,
            answers: Array(answers)
        )

        // 构造 IP+UDP 响应包（src=虚拟DNS, dst=原查询源）。
        return buildUdpPacket(
            srcIP: dnsServerIP,
            dstIP: srcIP,
            srcPort: 53,
            dstPort: srcPort,
            payload: responsePayload
        )
    }

    // MARK: - DNS 包解析

    private struct ParsedDns {
        let domain: String
        let qtype: UInt16
        let transactionID: UInt16
    }

    private func parseDnsQuery(_ data: Data) -> (String, UInt16, UInt16)? {
        guard data.count >= 12 else { return nil }
        let transactionID = (UInt16(data[0]) << 8) | UInt16(data[1])

        // 跳过 Header（12 字节），解析 QNAME。
        var offset = 12
        var labels: [String] = []
        while offset < data.count {
            let len = Int(data[offset])
            if len == 0 { offset += 1; break }
            if (len & 0xc0) == 0xc0 { return nil }  // 压缩指针不应出现在查询里
            guard offset + len + 1 <= data.count else { return nil }
            let label = data.subdata(in: (offset + 1)..<(offset + 1 + len))
            if let s = String(data: label, encoding: .ascii) {
                labels.append(s)
            }
            offset += len + 1
        }
        guard offset + 4 <= data.count else { return nil }
        let qtype = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])

        let domain = labels.joined(separator: ".")
        guard !domain.isEmpty else { return nil }
        return (domain, qtype, transactionID)
    }

    // MARK: - DNS 响应构造

    private func buildDnsResponse(transactionID: UInt16, domain: String, qtype: UInt16, answers: [String]) -> Data {
        var data = Data()
        // Header：ID, flags=0x8180(标准响应+递归), QDCOUNT=1, ANCOUNT=answers.count
        data.append(UInt8(transactionID >> 8))
        data.append(UInt8(transactionID & 0xff))
        data.append(contentsOf: [0x81, 0x80])
        data.append(UInt8(0)); data.append(UInt8(1))  // QDCOUNT=1
        let ancount = UInt16(answers.count)
        data.append(UInt8(ancount >> 8)); data.append(UInt8(ancount & 0xff))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // NSCOUNT=0, ARCOUNT=0

        // Question 段（原样回写域名）
        for label in domain.split(separator: ".") {
            guard let bytes = String(label).data(using: .ascii) else { continue }
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        data.append(0x00)  // QNAME 终止
        data.append(UInt8(qtype >> 8)); data.append(UInt8(qtype & 0xff))  // QTYPE
        data.append(contentsOf: [0x00, 0x01])  // QCLASS=IN

        // Answer 段
        for ip in answers {
            // 压缩指针指向 QNAME（0xC00C）
            data.append(contentsOf: [0xC0, 0x0C])
            // type + class
            data.append(UInt8(qtype >> 8)); data.append(UInt8(qtype & 0xff))
            data.append(contentsOf: [0x00, 0x01])
            // TTL=300
            data.append(contentsOf: [0x00, 0x00, 0x01, 0x2C])

            if qtype == 1, let ipBytes = ipv4Bytes(ip) {
                // A 记录：4 字节
                data.append(contentsOf: [0x00, 0x04])
                data.append(contentsOf: ipBytes)
            } else if qtype == 28, let ipBytes = ipv6Bytes(ip) {
                // AAAA 记录：16 字节
                data.append(contentsOf: [0x00, 0x10])
                data.append(contentsOf: ipBytes)
            }
        }
        return data
    }

    private func ipv4Bytes(_ ip: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr, Array.init)
    }

    private func ipv6Bytes(_ ip: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, ip, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.__u6_addr.__u6_addr8, Array.init)
    }

    // MARK: - IP+UDP 包解析/构造

    private func parseDnsPacket(_ data: Data) -> (String, String, UInt16, Data)? {
        guard data.count >= 28 else { return nil }  // IPv4(20) + UDP(8) 最小
        let version = data[0] >> 4
        guard version == 4 else { return nil }  // 阶段 1 只处理 IPv4

        let ihl = Int(data[0] & 0x0f) * 4
        guard ihl >= 20, data.count >= ihl + 8 else { return nil }

        let protocolNum = data[9]
        guard protocolNum == 17 else { return nil }  // UDP

        let srcIP = "\(data[12]).\(data[13]).\(data[14]).\(data[15])"
        let dstIP = "\(data[16]).\(data[17]).\(data[18]).\(data[19])"

        let srcPort = (UInt16(data[ihl]) << 8) | UInt16(data[ihl + 1])
        let dstPort = (UInt16(data[ihl + 2]) << 8) | UInt16(data[ihl + 3])

        let udpPayload = data.subdata(in: (ihl + 8)..<data.count)
        return (srcIP, dstIP, srcPort, udpPayload)
    }

    private func buildUdpPacket(srcIP: String, dstIP: String, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        var packet = Data()

        // IPv4 Header（20 字节，无选项）
        let totalLength = UInt16(20 + 8 + payload.count)
        packet.append(contentsOf: [0x45])  // version=4, ihl=5
        packet.append(0x00)  // DSCP/ECN
        packet.append(UInt8(totalLength >> 8)); packet.append(UInt8(totalLength & 0xff))
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // ID, flags, offset
        packet.append(0x40)  // TTL=64
        packet.append(0x11)  // protocol=UDP
        // checksum=0（内核/utun 会补算）
        packet.append(contentsOf: [0x00, 0x00])
        // src/dst IP
        for part in srcIP.split(separator: ".") {
            packet.append(UInt8(String(part)) ?? 0)
        }
        for part in dstIP.split(separator: ".") {
            packet.append(UInt8(String(part)) ?? 0)
        }

        // UDP Header（8 字节）
        packet.append(UInt8(srcPort >> 8)); packet.append(UInt8(srcPort & 0xff))
        packet.append(UInt8(dstPort >> 8)); packet.append(UInt8(dstPort & 0xff))
        let udpLength = UInt16(8 + payload.count)
        packet.append(UInt8(udpLength >> 8)); packet.append(UInt8(udpLength & 0xff))
        packet.append(contentsOf: [0x00, 0x00])  // checksum=0

        // Payload
        packet.append(payload)
        return packet
    }
}
