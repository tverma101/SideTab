import XCTest
@testable import SideScreen

final class USBBridgeRepairTests: XCTestCase {
    func testRestoredTabletReportsReverseReestablishment() {
        let message = USBBridgeRepair.resultMessage(for: .connected(serial: "R52X30G5TNB"))

        XCTAssertTrue(message.contains("R52X30G5TNB"))
        XCTAssertTrue(message.contains("reverse tunnel"))
    }

    func testSeriallessConnectedStateStillReportsRestoration() {
        let message = USBBridgeRepair.resultMessage(for: .connected(serial: nil))

        XCTAssertTrue(message.contains("the tablet"))
    }

    func testNoTabletAfterRestartPointsAtCableAndUsbDebugging() {
        let message = USBBridgeRepair.resultMessage(for: .notDetected)

        XCTAssertTrue(message.contains("no tablet is visible"))
    }

    func testStillUnreachablePointsAtSquattedPort() {
        let message = USBBridgeRepair.resultMessage(for: .serverUnreachable)

        XCTAssertTrue(message.contains("5037"))
    }

    func testAuthorizationAndOfflineAfterRepairBlameTheTabletSide() {
        let authorized = USBBridgeRepair.resultMessage(for: .authorizationRequired(serial: "R52X30G5TNB"))
        let offline = USBBridgeRepair.resultMessage(for: .offline(serial: "R52X30G5TNB"))

        XCTAssertTrue(authorized.contains("Allow"))
        XCTAssertTrue(offline.contains("offline"))
    }
}