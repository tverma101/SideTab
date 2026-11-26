import XCTest
@testable import SideScreen

final class ConnectionModeAdmissionTests: XCTestCase {
    func testUSBAcceptsOnlyLoopbackPeers() {
        XCTAssertTrue(ConnectionModeAdmission.accepts(.usb, peerIsLoopback: true))
        XCTAssertFalse(ConnectionModeAdmission.accepts(.usb, peerIsLoopback: false))
    }

    func testWirelessAcceptsOnlyLANPeers() {
        XCTAssertTrue(ConnectionModeAdmission.accepts(.wireless, peerIsLoopback: false))
        XCTAssertFalse(ConnectionModeAdmission.accepts(.wireless, peerIsLoopback: true))
    }
}
