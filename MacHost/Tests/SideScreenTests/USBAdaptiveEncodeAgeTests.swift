import XCTest
@testable import SideScreen

final class USBAdaptiveEncodeAgeTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// One encoded frame every 8 ms from `start` up to and including `end`.
    private func encode(
        _ controller: USBAdaptiveLoadController,
        ageMs: UInt64,
        encodeMs: UInt64? = nil,
        from start: UInt64,
        through end: UInt64
    ) {
        var t = start
        while t <= end {
            controller.observeEncodedFrameAge(
                ageNs: ageMs * ms,
                encodeNs: encodeMs.map { $0 * ms },
                nowNs: t * ms
            )
            t += 8
        }
    }

    func testSingleOverBudgetEncodeAgeDoesNotDownshift() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 50, maxFPS: 120)

        controller.observeEncodedFrameAge(ageNs: 60 * ms, nowNs: 100 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)
        // Host encode pressure keeps its own streak; it must not spend a
        // transport strike (e3dacc1 separated the two).
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 1)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
    }

    /// When big motion starts after a still screen, rate control overshoots
    /// and encode time plateaus at 37-43 ms for ~2 s on a path that then
    /// encodes 120 FPS at ~7 ms. A flat plateau is pipelining, not a queue.
    func testMotionStartEncodePlateauDoesNotDownshift() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 51, maxFPS: 120)

        encode(controller, ageMs: 43, from: 100, through: 2_500)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 2_500 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 0)
    }

    func testBriefQueueSpikeDoesNotDownshift() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 51, maxFPS: 120)

        encode(controller, ageMs: 60, from: 100, through: 300)
        controller.observeEncodedFrameAge(ageNs: 7 * ms, nowNs: 308 * ms)
        encode(controller, ageMs: 60, from: 316, through: 500)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 500 * ms), 120)
    }

    func testSustainedEncoderQueueDownshifts120To90() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 51, maxFPS: 120)

        encode(controller, ageMs: 60, from: 100, through: 340)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 340 * ms), 120)
        encode(controller, ageMs: 60, from: 348, through: 356)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 356 * ms), 90)
    }

    func testFortyNineMillisecondsIsBelow120PressureFloor() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 52, maxFPS: 120)

        encode(controller, ageMs: 49, from: 100, through: 1_000)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_000 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 0)
    }

    /// ScreenCaptureKit delivery delay inflates the age from capture, but
    /// dropping frames after capture cannot relieve it. The encoder's own time
    /// decides when it is known.
    func testEncoderTimeOverridesCaptureDeliveryDelay() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 56, maxFPS: 120)

        encode(controller, ageMs: 90, encodeMs: 9, from: 100, through: 1_000)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_000 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 0)

        encode(controller, ageMs: 10, encodeMs: 60, from: 1_008, through: 1_300)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_300 * ms), 90)
    }

    func testNinetyTierUsesSixFrameIntervalsAsThreshold() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 53, maxFPS: 120)

        // Get to 90 first.
        controller.observeSendsInFlight(generation: 53, count: 3, nowNs: 100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 90)

        // Six 90-Hz frame intervals are ~66.7ms, so 60ms is not pressure.
        encode(controller, ageMs: 60, from: 400, through: 1_000)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_000 * ms), 90)

        // A sustained >66.7ms queue is enough for 90->60.
        encode(controller, ageMs: 80, from: 1_008, through: 1_300)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_300 * ms), 60)
    }

    func testRecoveryGraceSuppressesLargeEncodeAge() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 54, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        encode(controller, ageMs: 100, from: 150, through: 340)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 340 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 0)

        // Once the 250ms recovery grace expires, the same host-side slippage
        // becomes real pressure again when it persists.
        encode(controller, ageMs: 60, from: 360, through: 620)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 620 * ms), 90)
    }

    func testEncodeAgeIsIgnoredWhenAdaptiveControllerIsInactive() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 55, maxFPS: 60)

        controller.observeEncodedFrameAge(ageNs: 500 * ms, nowNs: 100 * ms)
        controller.observeEncodedFrameAge(ageNs: 500 * ms, nowNs: 200 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 60, nowNs: 200 * ms), 60)
        XCTAssertEqual(controller.snapshotForTest().encodeAgeStrikes, 0)
    }
}
