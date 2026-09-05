import XCTest
@testable import SideScreen

final class WirelessServiceIdentityTests: XCTestCase {
    func testIdentityIsStableAndCrossPlatformCompatible() {
        let token = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(WirelessServiceIdentity.name(for: token), "SideScreen-630dcd2966c43366")
    }

    func testServiceTypeIsBonjourTCP() {
        XCTAssertEqual(WirelessServiceIdentity.serviceType, "_sidescreen._tcp")
    }
}
