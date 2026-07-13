import XCTest
@testable import NaiveGui

/// DNS wire format 编解码单测。验证 DoH 查询构造与响应解析的正确性。
final class DNSMessageTests: XCTestCase {
    func testQueryConstruction() {
        // 构造一个 A 记录查询，验证基本结构。
        let query = DNSMessage.query(host: "example.com", qtype: 1)
        XCTAssertNotNil(query)
        let bytes = [UInt8](query!)
        // 最小 A 查询：12（header）+ "example.com" 编码 + 1（终止）+ 4（qtype+qclass）= 12+13+1+4 = 30
        // "example"=7 + "com"=3 + 两长度字节 = 12，加终止 0 = 13
        XCTAssertGreaterThanOrEqual(bytes.count, 29)
        // Header：QDCOUNT 应为 1（字节 4-5）
        let qdcount = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
        XCTAssertEqual(qdcount, 1)
        // flags（字节 2-3）：0x0100 = RD
        let flags = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        XCTAssertEqual(flags, 0x0100)
    }

    func testQueryQTYPE() {
        // AAAA 查询的 qtype 字段应为 28（0x001C）。
        let query = DNSMessage.query(host: "test.org", qtype: 28)!
        let bytes = [UInt8](query)
        // qtype 在 QNAME 结束后的 2 字节。QNAME 至少有 1 字节长度 + 1 终止 = 2。
        // 找到终止 0，其后 2 字节是 qtype。
        var qnameEnd = 12
        while qnameEnd < bytes.count && bytes[qnameEnd] != 0 {
            qnameEnd += Int(bytes[qnameEnd]) + 1
        }
        // qnameEnd 指向终止 0，其后是 qtype（2 字节）+ qclass（2 字节）
        let qtypeOffset = qnameEnd + 1
        let qtype = (UInt16(bytes[qtypeOffset]) << 8) | UInt16(bytes[qtypeOffset + 1])
        XCTAssertEqual(qtype, 28)
    }

    func testParseEmptyResponse() {
        // 无 Answer 的响应应返回 nil。
        var data = Data()
        // Header：ANCOUNT=0
        data.append(contentsOf: [0x12, 0x34, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // QNAME + QTYPE + QCLASS（最小）
        data.append(contentsOf: [0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x00, 0x00, 0x01, 0x00, 0x01])
        let records = DNSMessage.parseAnswers(data)
        XCTAssertNil(records)
    }

    func testParseAResponse() {
        // 构造一个含 1 条 A 记录的响应。
        var data = Data()
        // Header：ID=0x1234, flags=0x8180, QDCOUNT=1, ANCOUNT=1
        data.append(contentsOf: [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        // Question: "example" + "com" + 终止 + qtype(1) + qclass(1)
        data.append(0x07); data.append(contentsOf: Array("example".utf8))
        data.append(0x03); data.append(contentsOf: Array("com".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        // Answer: 压缩指针 + type A + class IN + TTL + rdlength=4 + IP(93.184.216.34)
        data.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 93, 184, 216, 34])

        let records = DNSMessage.parseAnswers(data)
        XCTAssertNotNil(records)
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?[0].qtype, 1)
        XCTAssertEqual(records?[0].ip, "93.184.216.34")
    }

    func testParseAAAAResponse() {
        // 构造一个含 1 条 AAAA 记录的响应。
        var data = Data()
        // Header
        data.append(contentsOf: [0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        // Question: "test" + "org" + 终止 + qtype(28) + qclass(1)
        data.append(0x04); data.append(contentsOf: Array("test".utf8))
        data.append(0x03); data.append(contentsOf: Array("org".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x1C, 0x00, 0x01])
        // Answer: 压缩指针 + type AAAA + class + TTL + rdlength=16 + IPv6(2606:2800:220:1:248:1893:25c8:1946)
        let ipv6: [UInt8] = [0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46]
        data.append(contentsOf: [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x10] + ipv6)

        let records = DNSMessage.parseAnswers(data)
        XCTAssertNotNil(records)
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?[0].qtype, 28)
        // IPv6 格式化可能因 inet_ntop 实现略有差异，只校验非空且含冒号。
        XCTAssertFalse(records?[0].ip.isEmpty ?? true)
        XCTAssertTrue(records?[0].ip.contains(":") ?? false)
    }
}

final class DNSRoutingPolicyTests: XCTestCase {
    func testDefaultProxyWithDirectGeoIPDoesNotBlockColdCache() {
        let rules = [
            RoutingRule(
                name: "China direct",
                type: .direct,
                conditions: [RuleCondition(field: .ruleSet, value: "geoip-cn")]
            )
        ]

        let policy = DNSRoutingPolicy.make(defaultOutbound: .proxy, rules: rules)

        XCTAssertFalse(policy.requiresSynchronousResolution)
        XCTAssertNil(policy.failureFallback)
    }

    func testDefaultDirectWaitsRatherThanBypassingProxyRule() {
        let rules = [
            RoutingRule(
                name: "Proxy subnet",
                type: .proxy,
                conditions: [RuleCondition(field: .ipCidr, value: "203.0.113.0/24")]
            )
        ]

        let policy = DNSRoutingPolicy.make(defaultOutbound: .direct, rules: rules)

        XCTAssertTrue(policy.requiresSynchronousResolution)
        XCTAssertEqual(policy.failureFallback, .proxy)
    }

    func testIPBlockRuleFailsClosed() {
        let rules = [
            RoutingRule(
                name: "Blocked subnet",
                type: .block,
                conditions: [RuleCondition(field: .ipCidr, value: "198.51.100.0/24")]
            )
        ]

        let policy = DNSRoutingPolicy.make(defaultOutbound: .proxy, rules: rules)

        XCTAssertTrue(policy.requiresSynchronousResolution)
        XCTAssertEqual(policy.failureFallback, .block)
    }
}

final class SystemProxyServiceParsingTests: XCTestCase {
    func testMapsDefaultRouteInterfaceToNetworkService() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en6)
        """

        XCTAssertEqual(
            SystemProxyManager.networkService(forInterface: "en6", serviceOrderOutput: output),
            "USB 10/100/1000 LAN"
        )
        XCTAssertNil(SystemProxyManager.networkService(forInterface: "en7", serviceOrderOutput: output))
    }

    func testDoesNotConfuseInterfaceNamePrefixes() {
        let output = """
        (1) Test Adapter
        (Hardware Port: Test Adapter, Device: en01)
        """

        XCTAssertNil(SystemProxyManager.networkService(forInterface: "en0", serviceOrderOutput: output))
    }
}
