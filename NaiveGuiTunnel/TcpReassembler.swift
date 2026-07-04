import Darwin
import Foundation

/// 简化版用户态 TCP 栈：从 utun 的原始 IP 包重建 TCP 连接，提取字节流。
///
/// 不使用 lwIP（避免 C 桥接复杂性），而是实现一个精简的 TCP 状态机：
/// - 跟踪每条 TCP 连接的 (srcIP, srcPort, dstIP, dstPort) 四元组
/// - 处理 SYN/SYN-ACK/ACK 握手（自动回复，让应用认为连接已建立）
/// - 提取 PAYLOAD 数据（PSH/Data 包）
/// - 处理 FIN/RST 关闭
/// - 维护序列号，回复 ACK
///
/// 重组出的字节流通过回调交给 TunnelEngine → 路由引擎 → 转发。
/// 反向流量（上游响应）通过 writeData 注入回 TCP 流，构造 IP+TCP 包发到 utun。
///
/// 注意：这是**代理场景**的简化栈，不是完整的 TCP 实现：
/// - 不做拥塞控制（代理转发，可靠性由端到端保证）
/// - 不做重传（丢失的包由应用层重试或上层 TCP 保证）
/// - 窗口固定大值（简化流量控制）
final class TcpReassembler {
    /// 一条 TCP 连接的状态。
    struct Connection {
        let key: String           // "srcIP:srcPort-dstIP:dstPort"
        let srcIP: String
        let srcPort: UInt16
        let dstIP: String
        let dstPort: UInt16
        var state: TcpState
        var ourSeq: UInt32        // 我们（虚拟栈）的发送序列号
        var theirSeq: UInt32      // 对端（应用）的序列号
        var sendBuffer: Data      // 待发到 utun 的数据（上游响应）
    }

    enum TcpState {
        case listening
        case synReceived
        case established
        case closing
    }

    /// 收到应用 TCP 数据时的回调（host, port, payload）。
    /// TunnelEngine 用此把数据转发到路由引擎决定的上游。
    var onData: ((String, UInt16, Data) -> Void)?

    /// 连接建立时的回调（host, port）。
    var onConnect: ((String, UInt16) -> Void)?

    /// 连接关闭时的回调（host, port）。
    var onDisconnect: ((String, UInt16) -> Void)?

    /// 需要发到 utun 的 IP 包（ACK、SYN-ACK、数据响应等）。
    var outputPackets: [Data] = []

    private var connections: [String: Connection] = [:]
    private let lock = NSLock()

    init() {}

    // MARK: - 输入处理（从 utun 收到的包）

    /// 处理一个 IP 包。如果是 TCP 包，更新连接状态、提取数据、生成 ACK。
    func input(_ packet: Data) {
        guard packet.count >= 40 else { return }  // IPv4(20) + TCP(20) 最小
        let version = packet[0] >> 4
        guard version == 4 else { return }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard ihl >= 20, packet.count >= ihl + 20 else { return }
        guard packet[9] == 6 else { return }  // TCP

        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        let srcPort = readUInt16(packet, at: ihl)
        let dstPort = readUInt16(packet, at: ihl + 2)
        let seq = readUInt32(packet, at: ihl + 4)
        let ack = readUInt32(packet, at: ihl + 8)
        let dataOffset = Int((packet[ihl + 12] >> 4) * 4)
        let flags = packet[ihl + 13]
        let payload = dataOffset < (packet.count - ihl)
            ? packet.subdata(in: (ihl + dataOffset)..<packet.count)
            : Data()

        let key = "\(srcIP):\(srcPort)-\(dstIP):\(dstPort)"

        lock.lock()
        handleTcp(
            key: key, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort,
            seq: seq, ack: ack, flags: flags, payload: payload
        )
        lock.unlock()
    }

    private func handleTcp(key: String, srcIP: String, srcPort: UInt16,
                           dstIP: String, dstPort: UInt16,
                           seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        var conn = connections[key]

        // SYN：新连接（应用向目标发起连接）
        if flags & 0x02 != 0 {
            conn = Connection(
                key: key, srcIP: srcIP, srcPort: srcPort,
                dstIP: dstIP, dstPort: dstPort,
                state: .synReceived, ourSeq: UInt32.random(in: 1...UInt32.max/2),
                theirSeq: seq &+ 1, sendBuffer: Data()
            )
            // 回复 SYN-ACK
            let synAck = buildTcpPacket(
                srcIP: dstIP, dstIP: srcIP, srcPort: dstPort, dstPort: srcPort,
                seq: conn!.ourSeq, ack: conn!.theirSeq,
                flags: 0x12  // SYN+ACK
            )
            outputPackets.append(synAck)
            conn!.ourSeq &+= 1  // SYN 占一个序列号
            connections[key] = conn
            return
        }

        guard var conn else { return }

        // ACK：更新对端序列号
        if flags & 0x10 != 0 {
            if conn.state == .synReceived {
                conn.state = .established
                onConnect?(dstIP, dstPort)
            }
            conn.theirSeq = seq
        }

        // 数据（PSH 或带 payload 的 ACK）
        if !payload.isEmpty && conn.state == .established {
            conn.theirSeq = seq &+ UInt32(payload.count)
            // 回复 ACK
            let ackPacket = buildTcpPacket(
                srcIP: conn.dstIP, dstIP: conn.srcIP, srcPort: conn.dstPort, dstPort: conn.srcPort,
                seq: conn.ourSeq, ack: conn.theirSeq,
                flags: 0x10  // ACK
            )
            outputPackets.append(ackPacket)
            // 交给路由引擎
            onData?(conn.dstIP, conn.dstPort, payload)
        }

        // FIN：对端关闭
        if flags & 0x01 != 0 {
            conn.theirSeq = seq &+ 1
            let finAck = buildTcpPacket(
                srcIP: conn.dstIP, dstIP: conn.srcIP, srcPort: conn.dstPort, dstPort: conn.srcPort,
                seq: conn.ourSeq, ack: conn.theirSeq,
                flags: 0x11  // FIN+ACK
            )
            outputPackets.append(finAck)
            conn.ourSeq &+= 1
            conn.state = .closing
            onDisconnect?(conn.dstIP, conn.dstPort)
            connections.removeValue(forKey: key)
            return
        }

        // RST：强制关闭
        if flags & 0x04 != 0 {
            onDisconnect?(conn.dstIP, conn.dstPort)
            connections.removeValue(forKey: key)
            return
        }

        connections[key] = conn
    }

    // MARK: - 输出处理（上游响应 → 注入 utun）

    /// 向指定连接写入响应数据（来自上游/代理）。
    /// 构造 IP+TCP 数据包，加入 outputPackets 等待 TunnelEngine 取走发到 utun。
    func writeData(_ data: Data, toHost host: String, port: UInt16) {
        // 找到该目标的连接（反向 key：dstIP:dstPort-srcIP:srcPort）
        // 实际 key 是 "srcIP:srcPort-dstIP:dstPort"（应用→目标），
        // 我们写数据时是 目标→应用，所以要找 key 里 dstIP==host 的连接。
        lock.lock()
        for (key, var conn) in connections {
            if conn.dstIP == host && conn.dstPort == port {
                let packet = buildTcpPacket(
                    srcIP: conn.dstIP, dstIP: conn.srcIP, srcPort: conn.dstPort, dstPort: conn.srcPort,
                    seq: conn.ourSeq, ack: conn.theirSeq,
                    flags: 0x18,  // PSH+ACK
                    payload: data
                )
                outputPackets.append(packet)
                conn.ourSeq &+= UInt32(data.count)
                connections[key] = conn
                break
            }
        }
        lock.unlock()
    }

    /// 取走所有待输出的 IP 包（TunnelEngine 定期调用，发到 utun）。
    func flushOutputPackets() -> [Data] {
        lock.lock()
        let packets = outputPackets
        outputPackets.removeAll()
        lock.unlock()
        return packets
    }

    /// 关闭所有连接（停止时清理）。
    func reset() {
        lock.lock()
        connections.removeAll()
        outputPackets.removeAll()
        lock.unlock()
    }

    // MARK: - 包构造

    private func buildTcpPacket(srcIP: String, dstIP: String, srcPort: UInt16, dstPort: UInt16,
                                seq: UInt32, ack: UInt32, flags: UInt8,
                                payload: Data = Data()) -> Data {
        var packet = Data()
        let tcpLen = 20 + payload.count
        let totalLen = 20 + tcpLen

        // IPv4 header
        packet.append(0x45)  // ver=4, ihl=5
        packet.append(0x00)
        packet.append(UInt8(totalLen >> 8)); packet.append(UInt8(totalLen & 0xff))
        packet.append(contentsOf: [0x00, 0x00, 0x40, 0x00])  // ID, flags, TTL
        packet.append(0x06)  // TCP
        packet.append(contentsOf: [0x00, 0x00])  // checksum (let kernel/utun fix)
        appendIPv4Bytes(&packet, srcIP)
        appendIPv4Bytes(&packet, dstIP)

        // TCP header
        packet.append(UInt8(srcPort >> 8)); packet.append(UInt8(srcPort & 0xff))
        packet.append(UInt8(dstPort >> 8)); packet.append(UInt8(dstPort & 0xff))
        appendUInt32(&packet, seq)
        appendUInt32(&packet, ack)
        packet.append(0x50)  // data offset = 5 (20 bytes)
        packet.append(flags)
        packet.append(contentsOf: [0xff, 0xff])  // window
        packet.append(contentsOf: [0x00, 0x00])  // checksum
        packet.append(contentsOf: [0x00, 0x00])  // urgent pointer

        // Payload
        packet.append(payload)
        return packet
    }

    // MARK: - 辅助

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value >> 24))
        data.append(UInt8(value >> 16))
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private func appendIPv4Bytes(_ data: inout Data, _ ip: String) {
        for part in ip.split(separator: ".") {
            data.append(UInt8(String(part)) ?? 0)
        }
    }
}
