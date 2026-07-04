import XCTest
@testable import NaiveGui

/// IPCIDR / IPAddress 核心逻辑单测。这些是路由匹配的基础，必须正确。
final class IPCIDRTests: XCTestCase {
    func testIPv4Parse() {
        XCTAssertNotNil(IPAddress("192.168.1.1"))
        XCTAssertNotNil(IPAddress("0.0.0.0"))
        XCTAssertNotNil(IPAddress("255.255.255.255"))
        XCTAssertNil(IPAddress("not.an.ip.addr"))
        XCTAssertNil(IPAddress("192.168.1"))
        XCTAssertNil(IPAddress("192.168.1.1.1"))
    }

    func testIPv6Parse() {
        XCTAssertNotNil(IPAddress("::1"))
        XCTAssertNotNil(IPAddress("2001:db8::1"))
        XCTAssertNotNil(IPAddress("fe80::1"))
        XCTAssertNil(IPAddress("not::an::ip"))
    }

    func testIPv4CIDRContains() {
        let cidr = IPCIDR("192.168.1.0/24")
        XCTAssertNotNil(cidr)
        XCTAssertTrue(cidr!.contains(IPAddress("192.168.1.0")!))
        XCTAssertTrue(cidr!.contains(IPAddress("192.168.1.127")!))
        XCTAssertTrue(cidr!.contains(IPAddress("192.168.1.255")!))
        XCTAssertFalse(cidr!.contains(IPAddress("192.168.2.1")!))
        XCTAssertFalse(cidr!.contains(IPAddress("10.0.0.1")!))
    }

    func testIPv6CIDRContains() {
        let cidr = IPCIDR("2001:db8::/32")
        XCTAssertNotNil(cidr)
        XCTAssertTrue(cidr!.contains(IPAddress("2001:db8::1")!))
        XCTAssertTrue(cidr!.contains(IPAddress("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff")!))
        XCTAssertFalse(cidr!.contains(IPAddress("2001:db9::1")!))
    }

    func testFullPrefixCIDR() {
        // /32 精确匹配单个 IPv4
        let cidr = IPCIDR("10.0.0.5/32")!
        XCTAssertTrue(cidr.contains(IPAddress("10.0.0.5")!))
        XCTAssertFalse(cidr.contains(IPAddress("10.0.0.6")!))
    }

    func testZeroPrefixCIDR() {
        // /0 匹配所有 IPv4
        let cidr = IPCIDR("0.0.0.0/0")!
        XCTAssertTrue(cidr.contains(IPAddress("1.2.3.4")!))
        XCTAssertTrue(cidr.contains(IPAddress("255.255.255.255")!))
    }

    func testInvalidCIDR() {
        XCTAssertNil(IPCIDR("not.a.cidr"))
        // /33 前缀超长：IPv4 maxBits=32，33 > 32 应返回 nil。
        let oversize = IPCIDR("192.168.1.0/33")
        XCTAssertNil(oversize, "prefix /33 should be rejected for IPv4 (max 32), got bits=\(oversize?.bits ?? -1)")
        XCTAssertNil(IPCIDR("192.168.1.0/-1"))
        XCTAssertNil(IPCIDR("192.168.1.0/"))
    }

    func testIPv4RangeMode() {
        // sing-box IP set 用 range 模式（from-to）。
        let from = IPAddress("10.0.0.0")!
        let to = IPAddress("10.0.0.255")!
        let cidr = IPCIDR(rangeStart: from, rangeEnd: to)
        XCTAssertTrue(cidr.contains(IPAddress("10.0.0.100")!))
        XCTAssertTrue(cidr.contains(IPAddress("10.0.0.0")!))
        XCTAssertTrue(cidr.contains(IPAddress("10.0.0.255")!))
        XCTAssertFalse(cidr.contains(IPAddress("10.0.1.0")!))
    }

    func testMixedVersionDoesNotContain() {
        let v4cidr = IPCIDR("192.168.1.0/24")!
        XCTAssertFalse(v4cidr.contains(IPAddress("::1")!))
        let v6cidr = IPCIDR("::1/128")!
        XCTAssertFalse(v6cidr.contains(IPAddress("1.2.3.4")!))
    }
}
