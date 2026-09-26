import XCTest
@testable import SideScreen

final class PairingURLTests: XCTestCase {
    private let controlPortKey = "SideScreen_controlPort"
    private let token = Data((0..<32).map { UInt8($0) })

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        super.tearDown()
    }

    private func build(
        host: String = "192.168.1.42",
        port: UInt16 = 8888,
        token: Data? = nil,
        name: String = "x",
        alternateHosts: [String] = []
    ) -> String? {
        PairingURL.build(
            host: host,
            port: port,
            token: token ?? self.token,
            name: name,
            alternateHosts: alternateHosts
        )
    }

    func testBuildContainsAllFields() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = build(name: "Dat's MacBook")
        XCTAssertEqual(url?.hasPrefix("sidescreen://192.168.1.42:8888?"), true)
        XCTAssertEqual(url?.contains("t="), true)
        XCTAssertEqual(url?.contains("name="), true)
    }

    func testTokenIsBase64URLNoPadding() throws {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = try XCTUnwrap(build(host: "1.2.3.4", port: 9, token: Data((0..<32).map { _ in UInt8(0xAB) })))
        let tValue = try XCTUnwrap(queryValue(named: "t", in: url)).dropFirst(2)
        XCTAssertEqual(tValue.count, 43)
        XCTAssertFalse(tValue.contains("="))
        XCTAssertFalse(tValue.contains("+"))
        XCTAssertFalse(tValue.contains("/"))
    }

    func testNameIsURLEncoded() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = build(host: "1.2.3.4", port: 9, name: "Dat's MacBook")
        XCTAssertTrue(url?.contains("name=Dat's%20MacBook") == true)
    }

    /// Value of one query parameter, `name=` prefix included.
    private func queryValue(named name: String, in url: String) -> String? {
        url.split(separator: "?").dropFirst().first?.split(separator: "&")
            .first { $0.hasPrefix("\(name)=") }
            .map(String.init)
    }

    /// Android's Uri.getQueryParameter decodes a literal `+` as a space, so a
    /// Mac named "Bob's 100% + Mac" must not carry one through unescaped.
    func testPlusInNameIsEscaped() throws {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = try XCTUnwrap(build(host: "1.2.3.4", port: 9, name: "Bob's 100% + Mac"))
        let name = try XCTUnwrap(queryValue(named: "name", in: url))
        XCTAssertEqual(name, "name=Bob's%20100%25%20%2B%20Mac")
        XCTAssertFalse(name.contains("+"))
    }

    func testDefaultControlPortIsOmittedForLegacyCompatibility() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = build(host: "192.168.1.20", port: 54321, token: Data(repeating: 1, count: 32), name: "Mac")
        XCTAssertEqual(url?.contains("&c="), false)
    }

    func testExplicitControlPortIsEncoded() {
        UserDefaults.standard.set(55123, forKey: controlPortKey)
        let url = build(host: "192.168.1.20", port: 54321, token: Data(repeating: 2, count: 32), name: "Mac")
        XCTAssertTrue(url?.contains("&c=55123") == true)
    }

    func testExplicitDefaultControlPortStaysOmitted() {
        UserDefaults.standard.set(54322, forKey: controlPortKey)
        let url = build(host: "192.168.1.20", port: 54321, token: Data(repeating: 3, count: 32), name: "Mac")
        XCTAssertEqual(url?.contains("&c="), false)
    }

    func testIPv6AuthorityAndAlternateHostsAreEncoded() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = build(
            host: "2001:db8::1",
            port: 54321,
            token: Data(repeating: 4, count: 32),
            name: "Mac",
            alternateHosts: ["192.168.1.42", "2001:db8::1", "192.168.1.42"]
        )
        XCTAssertEqual(url?.hasPrefix("sidescreen://[2001:db8::1]:54321?"), true)
        XCTAssertTrue(url?.contains("&h=192.168.1.42") == true)
        XCTAssertEqual(url?.contains("&h=2001:db8::1"), false)
    }

    /// An unspecified address is the one host value the client accepts and can
    /// never connect to: it resolves to the tablet's own loopback, so the whole
    /// retry ladder is spent against itself.
    func testUnspecifiedHostProducesNoPayload() {
        for host in ["0.0.0.0", "::", "0:0:0:0:0:0:0:0", "[::]", "", "   "] {
            XCTAssertNil(build(host: host), "\(host) must not produce a pairing URL")
        }
    }

    func testUnpairableAlternateHostIsDropped() {
        UserDefaults.standard.removeObject(forKey: controlPortKey)
        let url = build(
            host: "192.168.1.20",
            port: 54321,
            name: "Mac",
            alternateHosts: ["0.0.0.0", "192.168.1.42", "::"]
        )
        XCTAssertTrue(url?.contains("&h=192.168.1.42") == true)
        XCTAssertEqual(url?.contains("0.0.0.0"), false)
        XCTAssertEqual(url?.contains("&h=::"), false)
    }

    func testUnpairableHostHelper() {
        XCTAssertFalse(PairingURL.isPairable("0.0.0.0"))
        XCTAssertFalse(PairingURL.isPairable("::"))
        XCTAssertFalse(PairingURL.isPairable("  "))
        XCTAssertTrue(PairingURL.isPairable("192.168.1.42"))
        XCTAssertTrue(PairingURL.isPairable("2603:6081:e200:162::1528"))
    }
}
