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

    func testLargeFrameDoesNotImplyCongestionWhenItIsTheOnlyThingQueued() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 20, maxFPS: 120)

        // A big frame may still be draining when the next one is sampled. One
        // frame's worth of queue is not a backlog.
        controller.observeSendBuffer(
            generation: 20,
            queuedBytes: 128 * 1024,
            frameBytes: 110 * 1024,
            nowNs: 100 * ms
        )

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().mildPressureStrikes, 0)
    }

    func testQueuedBacklogIsOnlyMildAndHealthyCompletionDecaysIt() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 21, maxFPS: 120)

        controller.observeSendBuffer(
            generation: 21,
            queuedBytes: 128 * 1024,
            frameBytes: 16 * 1024,
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

    /// Regression: the empty ADB loopback queue (0 bytes) used to be read as
    /// "no send-buffer headroom", which recorded pressure before every frame
    /// and kept the ladder pinned at 60 for the whole session.
    func testEmptyQueueIsHealthyAndLetsTheLadderClimbBack() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 22, maxFPS: 120)

        controller.observeSendsInFlight(generation: 22, count: 3, nowNs: 100 * ms)
        controller.observeSendsInFlight(generation: 22, count: 3, nowNs: 400 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 400 * ms), 60)

        var t: UInt64 = 500
        func healthyFrames(until end: UInt64) {
            while t < end {
                controller.observeSendBuffer(
                    generation: 22,
                    queuedBytes: 0,
                    frameBytes: 40_000,
                    nowNs: t * ms
                )
                controller.observeSendCompletion(
                    generation: 22,
                    durationNs: 1 * ms,
                    sendsInFlightAfter: 0,
                    nowNs: t * ms + 500_000
                )
                _ = controller.motionTargetFPS(maxFPS: 120, nowNs: t * ms + 600_000)
                t += 10
            }
        }

        healthyFrames(until: 2_500)
        XCTAssertEqual(controller.snapshotForTest().targetFPS, 90)
        healthyFrames(until: 7_600)
        XCTAssertEqual(controller.snapshotForTest().targetFPS, 120)
    }

    func testStartupGraceIgnoresConnectBurstThenArmsTheLadder() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 23, maxFPS: 120, startupGraceNs: 3_000 * ms, nowNs: 0)

        // Connect keyframe + decoder request + encoder rebuild, and slow first
        // encodes, all inside the startup window.
        controller.observeRecoveryPulse(nowNs: 50 * ms)
        controller.observeRecoveryPulse(nowNs: 300 * ms)
        controller.observeRecoveryPulse(nowNs: 600 * ms)
        for t in stride(from: UInt64(700), through: 1_000, by: 8) {
            controller.observeEncodedFrameAge(ageNs: 60 * ms, nowNs: t * ms)
        }
        controller.observeSendsInFlight(generation: 23, count: 3, nowNs: 1_000 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 2_900 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().lastPressureNs, 0)

        controller.observeSendsInFlight(generation: 23, count: 3, nowNs: 3_100 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 3_100 * ms), 90)
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
            queuedBytes: 1_000_000,
            frameBytes: 100_000,
            nowNs: 100 * ms
        )
        controller.observeSendsInFlight(generation: 10, count: 3, nowNs: 400 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 400 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().generation, 11)
    }
}
