import XCTest
@testable import SideScreen

final class USBAdaptiveMotionPacingTests: XCTestCase {
    private let frame120Ns: UInt64 = 1_000_000_000 / 120

    func testNinetyTargetProducesThreeOfFourCadenceFrom120Capture() {
        let pacer = USBAdaptiveFramePacer()
        var sent = 0

        for i in 0..<12 {
            let decision = pacer.decide(
                frameHasChanges: true,
                mutatesCapturedPixels: false,
                maxFPS: 120,
                motionTargetFPS: 90,
                nowNs: UInt64(i) * frame120Ns
            )
            if !decision.skip { sent += 1 }
            XCTAssertEqual(decision.targetFPS, 90)
        }

        XCTAssertEqual(sent, 9, "90 FPS on 120-Hz input should pass 3 of every 4 frames")
    }

    func testSixtyTargetProducesEveryOtherFrameFrom120Capture() {
        let pacer = USBAdaptiveFramePacer()
        var sent = 0

        for i in 0..<12 {
            let decision = pacer.decide(
                frameHasChanges: true,
                mutatesCapturedPixels: false,
                maxFPS: 120,
                motionTargetFPS: 60,
                nowNs: UInt64(i) * frame120Ns
            )
            if !decision.skip { sent += 1 }
            XCTAssertEqual(decision.targetFPS, 60)
        }

        XCTAssertEqual(sent, 6)
    }

    func testChangedFrameAfterIdlePunchesThroughConstrainedDeadline() {
        let pacer = USBAdaptiveFramePacer()

        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 60,
            nowNs: 0
        )
        _ = pacer.decide(
            frameHasChanges: false,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 60,
            nowNs: 2_500_000_000
        )

        // Only 1ms after a clean-frame send: the 60-FPS load cap would normally
        // reject this timestamp, but motion wake-up must be immediate.
        let wake = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 60,
            nowNs: 2_501_000_000
        )

        XCTAssertFalse(wake.skip)
        XCTAssertEqual(wake.targetFPS, 60)
        XCTAssertEqual(wake.phase, .active)
    }

    func testChangingLoadTargetSendsTransitionFrameImmediately() {
        let pacer = USBAdaptiveFramePacer()

        _ = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 120,
            nowNs: 0
        )

        let downshift = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 90,
            nowNs: frame120Ns
        )
        XCTAssertFalse(downshift.skip)
        XCTAssertEqual(downshift.targetFPS, 90)

        let upshift = pacer.decide(
            frameHasChanges: true,
            mutatesCapturedPixels: false,
            maxFPS: 120,
            motionTargetFPS: 120,
            nowNs: frame120Ns * 2
        )
        XCTAssertFalse(upshift.skip)
        XCTAssertEqual(upshift.targetFPS, 120)
    }
}
