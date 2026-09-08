import XCTest
@testable import SideScreen

final class USBAdaptiveFramePacerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testChangedFramesStayAtFull120() {
        let pacer = USBAdaptiveFramePacer()

        let first = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 0
        )
        XCTAssertEqual(first, .init(skip: false, targetFPS: 120, phase: .active))

        let next = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 9 * ms
        )
        XCTAssertEqual(next, .init(skip: false, targetFPS: 120, phase: .active))
    }

    func testCleanFramesRampDownFrom120To60To30To1() {
        let pacer = USBAdaptiveFramePacer()
        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 0
        )

        let settling = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 200 * ms
        )
        XCTAssertEqual(settling.targetFPS, 60)
        XCTAssertEqual(settling.phase, .settling)

        let idle = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 900 * ms
        )
        XCTAssertEqual(idle.targetFPS, 30)
        XCTAssertEqual(idle.phase, .idle)

        let deepIdle = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_500 * ms
        )
        XCTAssertEqual(deepIdle.targetFPS, 1)
        XCTAssertEqual(deepIdle.phase, .deepIdle)
    }

    func testDeepIdleActuallySuppressesCleanFramesForOneSecond() {
        let pacer = USBAdaptiveFramePacer()
        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 0
        )

        let firstIdleSend = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_500 * ms
        )
        XCTAssertFalse(firstIdleSend.skip)
        XCTAssertEqual(firstIdleSend.targetFPS, 1)

        let tooSoon = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 3_499 * ms
        )
        XCTAssertTrue(tooSoon.skip)
        XCTAssertEqual(tooSoon.targetFPS, 1)

        let due = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 3_500 * ms
        )
        XCTAssertFalse(due.skip)
        XCTAssertEqual(due.targetFPS, 1)
    }

    func testFirstChangedFrameAfterIdleWakesImmediatelyTo120() {
        let pacer = USBAdaptiveFramePacer()
        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 0
        )
        _ = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_500 * ms
        )

        // Only 1 ms after the last 1-FPS idle send: motion must still punch
        // through immediately rather than waiting for the idle interval.
        let wake = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_501 * ms
        )
        XCTAssertEqual(wake, .init(skip: false, targetFPS: 120, phase: .active))
    }

    func testMissingDirtyMetadataFailsOpen() {
        let pacer = USBAdaptiveFramePacer()
        let decision = pacer.decide(
            frameHasChanges: nil,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 5_000 * ms
        )
        XCTAssertEqual(decision, .init(skip: false, targetFPS: 120, phase: .bypass))
    }

    func testSyntheticPixelMutationBypassesPacing() {
        let pacer = USBAdaptiveFramePacer()
        let decision = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: true,
            maxFPS: 120,
            nowNs: 5_000 * ms
        )
        XCTAssertEqual(decision, .init(skip: false, targetFPS: 120, phase: .bypass))
    }

    func testForceNextPunchesThroughIdleGate() {
        let pacer = USBAdaptiveFramePacer()
        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 0
        )
        _ = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_500 * ms
        )
        pacer.forceNextFrame()

        let forced = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            nowNs: 2_501 * ms
        )
        XCTAssertEqual(forced, .init(skip: false, targetFPS: 120, phase: .active))
    }

    func testRateNeverExceedsConfiguredMaximum() {
        let pacer = USBAdaptiveFramePacer()
        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 90,
            nowNs: 0
        )

        let active = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 90,
            nowNs: 100 * ms
        )
        XCTAssertEqual(active.targetFPS, 90)

        let settling = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 90,
            nowNs: 200 * ms
        )
        XCTAssertEqual(settling.targetFPS, 60)
    }
}
