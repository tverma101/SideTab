import XCTest
@testable import SideScreen

final class LANAddressResolverTests: XCTestCase {
    func testReturnsValidIPv4WhenOnNetwork() {
        guard let ip = LANAddressResolver.primaryIPv4() else { return }
        let parts = ip.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        for p in parts {
            let n = Int(p)
            XCTAssertNotNil(n)
            XCTAssertGreaterThanOrEqual(n!, 0)
            XCTAssertLessThanOrEqual(n!, 255)
        }
        XCTAssertNotEqual(ip, "127.0.0.1", "Must skip loopback")
    }

    func testIsLoopbackHelper() {
        XCTAssertTrue(LANAddressResolver.isLoopback("127.0.0.1"))
        XCTAssertTrue(LANAddressResolver.isLoopback("::1"))
        XCTAssertFalse(LANAddressResolver.isLoopback("192.168.1.42"))
        XCTAssertFalse(LANAddressResolver.isLoopback("10.0.0.5"))
    }

    func testIsLinkLocalHelper() {
        XCTAssertTrue(LANAddressResolver.isLinkLocal("169.254.1.1"))
        XCTAssertTrue(LANAddressResolver.isLinkLocal("fe80::1"))
        XCTAssertFalse(LANAddressResolver.isLinkLocal("192.168.1.42"))
    }

    func testEndpointBracketsIPv6() {
        XCTAssertEqual(
            LANAddressResolver.endpoint(host: "2001:db8::1", port: 54321),
            "[2001:db8::1]:54321"
        )
        XCTAssertEqual(
            LANAddressResolver.endpoint(host: "192.168.1.42", port: 54321),
            "192.168.1.42:54321"
        )
    }

    /// Ranges a same-L2 peer can never open a socket to. Advertising any of them
    /// makes the panel report a working LAN the tablet cannot route to.
    func testUnreachableRangesAreRejected() {
        let rejected = [
            "0.0.0.0",            // unspecified
            "0.1.2.3",            // 0.0.0.0/8 "this host"
            "100.64.0.1",         // CGNAT / Tailscale lower bound
            "100.127.255.254",    // CGNAT / Tailscale upper bound
            "198.18.0.1",         // benchmarking
            "198.19.255.254",     // benchmarking
            "224.0.0.1",          // multicast
            "255.255.255.255",    // broadcast
            "127.0.0.1",          // loopback
            "::1",                // loopback
            "::",                 // unspecified
            "::ffff:192.168.1.5", // IPv4-mapped
            "fd00:fc12:6337:425c:8d1:9bab:2f9:2ef7", // ULA, the shape en0 hands out
            "fc00::1",            // ULA
            "fdff::1",            // ULA upper bound
            "fe00::1",            // unassigned fe00::/9
            "fe7f:ffff::1",       // unassigned fe00::/9 upper bound
            "fe80::1",            // link-local
            "febf::1",            // link-local upper bound
            "fec0::1",            // deprecated site-local
            "ff02::1",            // multicast
        ]
        for ip in rejected {
            XCTAssertFalse(LANAddressResolver.isPeerReachable(ip), "\(ip) must not be advertised")
        }
    }

    func testRoutableAddressesAreAccepted() {
        let accepted = [
            "192.168.1.42",       // RFC1918
            "10.24.7.9",          // RFC1918 on a VPN
            "172.16.0.1",         // RFC1918
            "172.31.255.254",     // RFC1918
            "100.63.255.255",     // just below CGNAT
            "100.128.0.1",        // just above CGNAT
            "198.17.255.255",     // just below benchmarking
            "198.20.0.1",         // just above benchmarking
            "223.255.255.254",    // just below multicast
            "8.8.8.8",
            "2001:db8::1",        // global, documentation range
            "2603:6081:e200:162:cf9:8ec0:e001:d12", // global
            "2603:6081:e200:162::1528",            // global, compressed hextets
            "2fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", // top of 2000::/3
        ]
        for ip in accepted {
            XCTAssertTrue(LANAddressResolver.isPeerReachable(ip), "\(ip) must be advertised")
        }
    }

    func testLinkLocalScopeSuffixDoesNotResurrectAnAddress() {
        XCTAssertFalse(LANAddressResolver.isPeerReachable("fe80::1%en0"))
        XCTAssertFalse(LANAddressResolver.isPeerReachable("169.254.1.1%en0"))
    }

    func testGarbageInputIsRejectedRatherThanGuessedAt() {
        for ip in ["", "not-an-ip", "999.1.1.1", "1.2.3", "2001:zzzz::1", "::ffff:1.2.3.4"] {
            XCTAssertFalse(LANAddressResolver.isPeerReachable(ip), "\(ip) must not be advertised")
        }
    }

    /// A rotating RFC 4941 temporary must not outrank an address that has
    /// already been up, and both must stay in the list as fallbacks.
    func testEstablishedAddressOutranksAFreshArrivalOnTheSameInterface() {
        let established = LANAddressResolver.Candidate(
            interfaceName: "en0", family: sa_family_t(AF_INET6), address: "2603:1::1", isEstablished: true
        )
        let fresh = LANAddressResolver.Candidate(
            interfaceName: "en0", family: sa_family_t(AF_INET6), address: "2603:1::2", isEstablished: false
        )
        XCTAssertTrue(LANAddressResolver.rank(established) < LANAddressResolver.rank(fresh))
        XCTAssertFalse(LANAddressResolver.rank(fresh) < LANAddressResolver.rank(established))
    }

    func testPhysicalInterfaceStillOutranksAnEstablishedVirtualOne() {
        let virtualEstablished = LANAddressResolver.Candidate(
            interfaceName: "utun3", family: sa_family_t(AF_INET), address: "10.24.7.9", isEstablished: true
        )
        let physicalFresh = LANAddressResolver.Candidate(
            interfaceName: "en0", family: sa_family_t(AF_INET), address: "192.168.1.42", isEstablished: false
        )
        XCTAssertTrue(LANAddressResolver.rank(physicalFresh) < LANAddressResolver.rank(virtualEstablished))
    }

    func testCandidatesAreDeduplicatedAndDoNotRepeatAddresses() {
        let hosts = LANAddressResolver.preferredHosts()
        XCTAssertEqual(hosts.count, Set(hosts).count, "preferredHosts must not repeat an address")
        XCTAssertFalse(hosts.contains("0.0.0.0"))
        for host in hosts {
            XCTAssertTrue(LANAddressResolver.isPeerReachable(host), "\(host) is not peer-reachable")
        }
    }
}
