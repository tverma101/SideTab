@testable import SideScreen
import XCTest

final class WirelessSettleRefreshPolicyTests: XCTestCase {
    private typealias Policy = WirelessSettleRefreshPolicy

    private func action(
        step: Int,
        delivered: Bool = true,
        lastOutputBytes: Int,
        previousStepEncoded: Bool = false,
        resent: Bool = false,
        keyframeDue: Bool = false
    ) -> Policy.Action {
        Policy.action(
            step: step,
            delivered: delivered,
            lastOutputBytes: lastOutputBytes,
            previousStepEncoded: previousStepEncoded,
            resent: resent,
            keyframeDue: keyframeDue
        )
    }

    /// A cursor blink, a keystroke or the last frame of a scroll: re-encoding
    /// the same picture measured at most 2.6 KB and 0.1 dB, so nothing runs
    /// before the one confirming re-send.
    func testSmallDeliveredChangeIsNotRefreshed() {
        XCTAssertEqual(action(step: 0, lastOutputBytes: 1_000), .none)
        XCTAssertEqual(action(step: 0, lastOutputBytes: 42 * 1024), .none)
        XCTAssertEqual(action(step: 1, lastOutputBytes: 1_000), .none)
    }

    /// A window switch or dialog goes out soft; refreshes measured 140-280 KB
    /// and +3-6 dB, so the chain runs while each refresh still carries detail.
    func testLargeChangeRefinesUntilARefreshComesBackSmall() {
        XCTAssertEqual(action(step: 0, lastOutputBytes: 700 * 1024), .refresh)
        XCTAssertEqual(action(step: 1, lastOutputBytes: 150 * 1024, previousStepEncoded: true), .refresh)
        XCTAssertEqual(action(step: 3, lastOutputBytes: 12 * 1024, previousStepEncoded: true), .refresh)
        XCTAssertEqual(action(step: 4, lastOutputBytes: 2 * 1024, previousStepEncoded: true), .none)
    }

    /// Refinement only continues a chain that is already refining: a small
    /// change frame must not start one at a later step.
    func testLaterStepDoesNotStartRefinementFromTheChangeFrame() {
        XCTAssertEqual(action(step: 1, lastOutputBytes: 20 * 1024, previousStepEncoded: false), .none)
    }

    /// A change skipped by Wi-Fi pressure never reached the tablet, so every
    /// step retries until one is accepted, whatever the last output size was.
    func testUndeliveredChangeIsAlwaysRefreshed() {
        for step in 0..<Policy.stepOffsetsNs.count {
            XCTAssertEqual(action(step: step, delivered: false, lastOutputBytes: 0), .refresh, "step \(step)")
        }
    }

    func testKeyframeOnlyAtTheKeyframeStepWhenDue() {
        XCTAssertEqual(action(step: Policy.keyframeStep, lastOutputBytes: 0, keyframeDue: true), .keyframe)
        XCTAssertEqual(action(step: Policy.keyframeStep, delivered: false, lastOutputBytes: 0, keyframeDue: true), .keyframe)
        XCTAssertEqual(action(step: 0, lastOutputBytes: 0, keyframeDue: true), .none)
        XCTAssertEqual(action(step: Policy.keyframeStep, lastOutputBytes: 0, resent: true), .none)
    }

    /// A tablet can drop the final frame after the Mac delivered it (an old
    /// build discards late decoded frames), and nothing else would replace
    /// it on a still screen. One ~1-2 KB re-send covers that; a chain that
    /// already re-encoded the frame has covered it.
    func testSettledFrameIsResentOnceAtTheKeyframeStep() {
        XCTAssertEqual(action(step: Policy.keyframeStep, lastOutputBytes: 1_000), .refresh)
        XCTAssertEqual(action(step: Policy.keyframeStep, lastOutputBytes: 1_000, resent: true), .none)
        XCTAssertEqual(
            action(step: Policy.keyframeStep + 1, lastOutputBytes: 1_500, previousStepEncoded: true, resent: true),
            .none
        )
    }

    /// Steps up to the keyframe step always run so a still screen can be
    /// re-anchored; after it only a delivering or refining chain continues.
    func testChainLengthFollowsWhetherItStillHasWork() {
        XCTAssertTrue(Policy.continues(afterStep: 0, action: .none))
        XCTAssertTrue(Policy.continues(afterStep: Policy.keyframeStep - 1, action: .none))
        XCTAssertFalse(Policy.continues(afterStep: Policy.keyframeStep, action: .none))
        XCTAssertTrue(Policy.continues(afterStep: Policy.keyframeStep, action: .keyframe))
        XCTAssertTrue(Policy.continues(afterStep: Policy.keyframeStep, action: .refresh))
        XCTAssertFalse(Policy.continues(afterStep: Policy.stepOffsetsNs.count - 1, action: .refresh))
    }

    /// The IDR refreshed at the keyframe step comes out softer than the chain
    /// it replaced, so at least one later step must exist to refine it.
    func testKeyframeStepIsFollowedByARefineStep() {
        XCTAssertLessThan(Policy.keyframeStep + 1, Policy.stepOffsetsNs.count)
        XCTAssertEqual(Policy.stepOffsetsNs, Policy.stepOffsetsNs.sorted())
    }
}
