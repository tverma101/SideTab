import XCTest
@testable import SideScreen

final class EncoderGOPPolicyTests: XCTestCase {
    func testLegacyUSBThirtyAndSixtyKeepOneSecondSafetyGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 30,
                adaptiveUSBEnabled: true
            ),
            1
        )
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 60,
                adaptiveUSBEnabled: true
            ),
            1
        )
    }

    func testAdaptiveHighRefreshUSBUsesFiveSecondSafetyGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 90,
                adaptiveUSBEnabled: true
            ),
            5
        )
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 120,
                adaptiveUSBEnabled: true
            ),
            5
        )
    }

    func testExplicitlyDisabledAdaptiveUSBKeepsLegacyOneSecondGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 120,
                adaptiveUSBEnabled: false
            ),
            1
        )
    }

    func testWirelessKeepsExistingFiveSecondSafetyGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: true,
                frameRate: 60,
                adaptiveUSBEnabled: false
            ),
            5
        )
    }
}
