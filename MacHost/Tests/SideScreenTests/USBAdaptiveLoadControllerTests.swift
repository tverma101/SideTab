import XCTest
@testable import SideScreen

final class USBAdaptiveLoadControllerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testSevereBacklogFalls120To90Then60WithCooldown() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 1, maxFPS: 120)

        controller.observeSendsInFlight(generation: 1, count: 3, nowNs: 100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 90)

        // A second transient inside the cooldown must not collapse straight to 60.
        controller.observeSendsInFlight(generation: 1, count: 3, nowNs: 200 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 200 * ms), 90)

        controller.observeSendsInFlight(generation: 1, count: 3, nowNs: 400 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 400 * ms), 60)
    }

    func testMildBacklogRequiresTwoStrikes() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 2, maxFPS: 120)

        controller.observeSendsInFlight(generation: 2, count: 2, nowNs: 100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)

        controller.observeSendsInFlight(generation: 2, count: 2, nowNs: 110 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 110 * ms), 90)
    }

    func testLargeFrameDoesNotImplyCongestionWhenBufferStillHasHeadroom() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 20, maxFPS: 120)

        // Frame is far larger than current TCP headroom, but Network.framework
        // can consume it asynchronously. This must not recreate the old false
        // "one whole frame must fit" rule.
        controller.observeSendBuffer(
            generation: 20,
            availableBytes: 64 * 1024,
            frameBytes: 1_000_000,
            nowNs: 100 * ms
        )

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
    }

    func testCriticalHeadroomIsOnlyMildAndHealthyCompletionDecaysIt() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 21, maxFPS: 120)

        controller.observeSendBuffer(
            generation: 21,
            availableBytes: 1,
            frameBytes: 1_000_000,
            nowNs: 100 * ms
        )
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 1)

        controller.observeSendCompletion(
            generation: 21,
            durationNs: 2 * ms,
            sendsInFlightAfter: 0,
            nowNs: 110 * ms
        )
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 110 * ms), 120)
    }

    func testHealthyPathRecovers60To90Then120Slowly() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 3, maxFPS: 120)

        controller.observeSendsInFlight(generation: 3, count: 3, nowNs: 100 * ms)
        controller.observeSendsInFlight(generation: 3, count: 3, nowNs: 400 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 400 * ms), 60)

        for i in 0..<12 {
            controller.observeSendCompletion(
                generation: 3,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (500 + UInt64(i) * 20) * ms
            )
        }

        // 60 -> 90 needs at least two pressure-free seconds.
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 2_300 * ms), 60)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 2_500 * ms), 90)

        for i in 0..<12 {
            controller.observeSendCompletion(
                generation: 3,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (2_600 + UInt64(i) * 20) * ms
            )
        }

        // 90 -> 120 is deliberately more conservative: five seconds.
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 7_400 * ms), 90)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 7_600 * ms), 120)
    }

    func testFailedRampAddsRecoveryPenalty() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 4, maxFPS: 120)

        controller.observeSendsInFlight(generation: 4, count: 3, nowNs: 100 * ms)
        controller.observeSendsInFlight(generation: 4, count: 3, nowNs: 400 * ms)
        for i in 0..<12 {
            controller.observeSendCompletion(
                generation: 4,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (500 + UInt64(i) * 20) * ms
            )
        }
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 2_500 * ms), 90)

        // Pressure within two seconds of that probe marks the ramp as failed.
        controller.observeSendsInFlight(generation: 4, count: 3, nowNs: 2_600 * ms)
        controller.observeSendsInFlight(generation: 4, count: 3, nowNs: 2_800 * ms)
        let snapshot = controller.snapshotForTest()
        XCTAssertEqual(snapshot.targetFPS, 60)
        XCTAssertEqual(snapshot.rampPenalty, 1)

        for i in 0..<12 {
            controller.observeSendCompletion(
                generation: 4,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (3_000 + UInt64(i) * 20) * ms
            )
        }

        // Penalty doubles the 60 -> 90 recovery delay from 2s to 4s.
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 6_700 * ms), 60)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 6_900 * ms), 90)
    }

    func testNinetyFPSConfigurationNeverInvents120() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 5, maxFPS: 90)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 90, nowNs: 0), 90)

        controller.observeSendsInFlight(generation: 5, count: 3, nowNs: 100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 90, nowNs: 100 * ms), 60)
    }

    func testStaleGenerationCannotAffectReplacementSession() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 10, maxFPS: 120)
        controller.reset(generation: 11, maxFPS: 120)

        controller.observeSendBuffer(
            generation: 10,
            availableBytes: 1,
            frameBytes: 100_000,
            nowNs: 100 * ms
        )
        controller.observeSendsInFlight(generation: 10, count: 3, nowNs: 400 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 400 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().generation, 11)
    }
}
