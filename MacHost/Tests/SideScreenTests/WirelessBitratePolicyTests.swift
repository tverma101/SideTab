import XCTest
@testable import SideScreen

final class WirelessBitratePolicyTests: XCTestCase {
    func testSinglePressureWindowDoesNotChangeBitrate() {
        var policy = WirelessBitratePolicy()
        let window = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 20,
            headroomMinBytes: 48 * 1024
        )

        XCTAssertEqual(0, policy.observe(window))
        XCTAssertEqual(1, policy.pressuredWindows)
    }

    func testTwoPressureWindowsStepDownExactlyOnce() {
        var policy = WirelessBitratePolicy()
        let window = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 20,
            headroomMinBytes: 48 * 1024
        )

        XCTAssertEqual(0, policy.observe(window))
        XCTAssertEqual(1, policy.observe(window))
        XCTAssertEqual(0, policy.pressuredWindows)
    }

    func testModeratePausesNeedLowHeadroomToCountAsPressure() {
        var policy = WirelessBitratePolicy()
        let healthyHeadroom = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 9,
            headroomMinBytes: 256 * 1024
        )
        let lowHeadroom = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 9,
            headroomMinBytes: 32 * 1024
        )

        XCTAssertEqual(0, policy.observe(healthyHeadroom))
        XCTAssertEqual(0, policy.pressuredWindows)
        XCTAssertEqual(0, policy.observe(lowHeadroom))
        XCTAssertEqual(1, policy.pressuredWindows)
    }

    func testFiveHealthyWindowsRecoverOneStep() {
        var policy = WirelessBitratePolicy()
        let pressured = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 24,
            headroomMinBytes: 32 * 1024
        )
        _ = policy.observe(pressured)
        XCTAssertEqual(1, policy.observe(pressured))

        let healthy = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 0,
            headroomMinBytes: 256 * 1024
        )
        for _ in 0..<4 {
            XCTAssertEqual(1, policy.observe(healthy))
        }
        XCTAssertEqual(0, policy.observe(healthy))
    }

    func testIncompleteWindowCannotRetune() {
        var policy = WirelessBitratePolicy()
        let tinyWindow = WirelessBitratePolicy.Window(
            completionSamples: 30,
            capturePauseDecisions: 30,
            headroomMinBytes: 0
        )

        for _ in 0..<10 {
            XCTAssertEqual(0, policy.observe(tinyWindow))
        }
        XCTAssertEqual(0, policy.pressuredWindows)
    }

    func testQualityLadderStepsAndClampsAtSixMbps() {
        XCTAssertEqual(50, WirelessBitratePolicy.targetMbps(baseTargetMbps: 60, stepDown: 1))
        XCTAssertEqual(30, WirelessBitratePolicy.targetMbps(baseTargetMbps: 60, stepDown: 3))
        XCTAssertEqual(12, WirelessBitratePolicy.targetMbps(baseTargetMbps: 30, stepDown: 2))
        XCTAssertEqual(6, WirelessBitratePolicy.targetMbps(baseTargetMbps: 20, stepDown: 99))
        XCTAssertEqual(6, WirelessBitratePolicy.targetMbps(baseTargetMbps: 6, stepDown: 1))
    }

    func testArbitraryExperimentalBitrateIsNotRemapped() {
        XCTAssertEqual(37, WirelessBitratePolicy.targetMbps(baseTargetMbps: 37, stepDown: 3))
    }

    func testResetRestoresFullQualityState() {
        var policy = WirelessBitratePolicy()
        let pressured = WirelessBitratePolicy.Window(
            completionSamples: 120,
            capturePauseDecisions: 30,
            headroomMinBytes: 16 * 1024
        )
        _ = policy.observe(pressured)
        _ = policy.observe(pressured)
        XCTAssertEqual(1, policy.stepDown)

        policy.reset()
        XCTAssertEqual(0, policy.stepDown)
        XCTAssertEqual(0, policy.pressuredWindows)
        XCTAssertEqual(0, policy.healthyWindows)
    }
}
