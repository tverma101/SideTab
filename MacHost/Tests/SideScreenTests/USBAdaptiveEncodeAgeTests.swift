import XCTest
@testable import SideScreen

final class USBAdaptiveEncodeAgeTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testSingleOverBudgetEncodeAgeDoesNotDownshift() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 50, maxFPS: 120)

        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 100 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 1)
    }

    func testTwoOverBudgetEncodeAgesDownshift120To90() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 51, maxFPS: 120)

        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 100 * ms)
        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 110 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 110 * ms), 90)
    }

    func testTwentyFourMillisecondsIsBelow120PressureFloor() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 52, maxFPS: 120)

        controller.observeEncodedFrameAge(ageNs: 24 * ms, nowNs: 100 * ms)
        controller.observeEncodedFrameAge(ageNs: 24 * ms, nowNs: 110 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 110 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
    }

    func testNinetyTierUsesThreeFrameIntervalsAsThreshold() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 53, maxFPS: 120)

        // Get to 90 first.
        controller.observeSendsInFlight(generation: 53, count: 3, nowNs: 100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 90)

        // Three 90-Hz frame intervals are ~33.3ms, so 30ms is not pressure.
        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 400 * ms)
        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 410 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 410 * ms), 90)

        // Two >33.3ms samples after the downshift cooldown are enough for 90->60.
        controller.observeEncodedFrameAge(ageNs: 40 * ms, nowNs: 500 * ms)
        controller.observeEncodedFrameAge(ageNs: 40 * ms, nowNs: 510 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 510 * ms), 60)
    }

    func testRecoveryGraceSuppressesLargeEncodeAge() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 54, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        controller.observeEncodedFrameAge(ageNs: 100 * ms, nowNs: 150 * ms)
        controller.observeEncodedFrameAge(ageNs: 100 * ms, nowNs: 200 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 200 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)

        // Once the 250ms recovery grace expires, the same host-side slippage
        // becomes real pressure again.
        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 360 * ms)
        controller.observeEncodedFrameAge(ageNs: 30 * ms, nowNs: 370 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 370 * ms), 90)
    }

    func testEncodeAgeIsIgnoredWhenAdaptiveControllerIsInactive() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 55, maxFPS: 60)

        controller.observeEncodedFrameAge(ageNs: 500 * ms, nowNs: 100 * ms)
        controller.observeEncodedFrameAge(ageNs: 500 * ms, nowNs: 200 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 60, nowNs: 200 * ms), 60)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
    }
}
