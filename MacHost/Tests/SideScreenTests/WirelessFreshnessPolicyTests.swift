import XCTest
@testable import SideScreen

final class WirelessFreshnessPolicyTests: XCTestCase {
    func testWirelessRemainsSixtyFPS() {
        XCTAssertEqual(WirelessFreshnessPolicy.targetFrameRate, 60)
        XCTAssertEqual(WirelessSessionProfile.frameRate, 60)
        XCTAssertEqual(
            WirelessSessionProfile.frameRate(for: .wireless, requested: 120),
            60
        )
    }

    func testUSBDoesNotInheritWirelessFrameCap() {
        XCTAssertEqual(
            WirelessSessionProfile.frameRate(for: .usb, requested: 120),
            120
        )
    }

    func testWirelessSenderWindowIsTighterThanGenericWindow() {
        let wireless = WirelessSessionProfile.backpressureLimits(for: .wireless)
        let generic = WirelessSessionProfile.backpressureLimits(for: .usb)

        XCTAssertEqual(wireless.maxInFlightFrames, 2)
        XCTAssertLessThan(wireless.maxInFlightFrames, generic.maxInFlightFrames)
        XCTAssertLessThanOrEqual(wireless.maxInFlightBytes, generic.maxInFlightBytes)
    }

    func testWirelessStaleBudgetIsTwoFrameIntervals() {
        XCTAssertEqual(
            WirelessFreshnessPolicy.maxDecodedFrameAgeNs,
            WirelessFreshnessPolicy.frameIntervalNs * 2
        )
        XCTAssertTrue(
            WirelessFreshnessPolicy.shouldRender(
                decodedLatencyNs: WirelessFreshnessPolicy.maxDecodedFrameAgeNs,
                isFirstFrame: false
            )
        )
        XCTAssertFalse(
            WirelessFreshnessPolicy.shouldRender(
                decodedLatencyNs: WirelessFreshnessPolicy.maxDecodedFrameAgeNs + 1,
                isFirstFrame: false
            )
        )
    }

    func testFirstFrameAlwaysRendersForStartupRecovery() {
        XCTAssertTrue(
            WirelessFreshnessPolicy.shouldRender(
                decodedLatencyNs: 500_000_000,
                isFirstFrame: true
            )
        )
    }

    func testWirelessAllowsAtMostOneExtraPresentationFrame() {
        XCTAssertEqual(WirelessFreshnessPolicy.targetExtraPresentationFrames, 1)
    }
}
