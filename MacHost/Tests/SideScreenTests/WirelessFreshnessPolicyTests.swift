import XCTest
@testable import SideScreen

final class WirelessFreshnessPolicyTests: XCTestCase {
    func testWirelessTargetIsSixtyFramesPerSecond() {
        XCTAssertEqual(60, WirelessFreshnessPolicy.targetFrameRate)
        XCTAssertEqual(16_666_666, WirelessFreshnessPolicy.frameIntervalNs)
        XCTAssertEqual(33_333_332, WirelessFreshnessPolicy.maxDecodedFrameAgeNs)
    }

    func testFirstFrameAndBoundaryAreFresh() {
        XCTAssertTrue(WirelessFreshnessPolicy.shouldRender(decodedLatencyNs: 1, isFirstFrame: true))
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

    func testWirelessSessionCapsRateButUsbPreservesRequestedRate() {
        XCTAssertEqual(
            WirelessFreshnessPolicy.targetFrameRate,
            WirelessSessionProfile.frameRate(for: .wireless, requested: 120)
        )
        XCTAssertEqual(90, WirelessSessionProfile.frameRate(for: .usb, requested: 90))
        XCTAssertEqual(
            WirelessFreshnessPolicy.averageBitrateMbps,
            WirelessSessionProfile.bitrateCap(for: .wireless)
        )
        XCTAssertNil(WirelessSessionProfile.bitrateCap(for: .usb))
    }
}
