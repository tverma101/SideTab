import Foundation

/// What each step of the Wi-Fi settle refresh does after the screen stops
/// changing. ScreenCaptureKit sends nothing for a still display, so the last
/// changed frame is all the tablet has until something moves again.
///
/// Measured offline with the production wireless VideoToolbox settings
/// (2800x1752 HEVC, 40 Mbps average / 60 Mbps peak, 2026-10-09):
/// - After scrolling, typing, video or a cursor blink, re-encoding the
///   unchanged frame returned 0.7-2.6 KB and improved luma PSNR by at most
///   0.1 dB.
/// - After a window switch or a dialog, the refreshes carried 140-280 KB each
///   and added 3-6 dB before settling.
/// - A routine IDR on a still screen cost 650-880 KB and came out 1-2 dB
///   below the refined P-frame chain it replaced.
///
/// So a step encodes only to deliver a frame that never reached the encoder,
/// or while the previous output says VideoToolbox still has detail to add.
/// Otherwise the settled frame is re-sent once, at the keyframe step: that
/// ~1-2 KB P-frame covers any receiver that dropped the final frame, such as
/// a tablet build that discards a late decoded frame. The routine keyframe
/// stays rare (`EncoderGOPPolicy`).
enum WirelessSettleRefreshPolicy {
    enum Action: Equatable {
        case none
        case refresh
        case keyframe
    }

    /// Step times, measured from the last change.
    static let stepOffsetsNs: [UInt64] = [
        80_000_000, 250_000_000, 600_000_000, 1_200_000_000, 2_000_000_000,
    ]

    /// The step that may re-anchor a still screen on an IDR, and that re-sends
    /// the settled frame when no earlier step did. Later steps refine that
    /// IDR, which comes out softer than the chain it replaced.
    static let keyframeStep = 2

    /// The first refresh runs only after an output at least this large.
    /// Every motion frame measured stayed under 42 KB with nothing left to
    /// refine; the smallest change that still gained (a dialog) was 92 KB.
    static let refineStartBytes = 48 * 1024

    /// Later refreshes continue while the previous one carried this much.
    /// Refreshes with nothing left to add came back at 0.7-2.6 KB.
    static let refineContinueBytes = 4 * 1024

    /// - Parameters:
    ///   - delivered: VideoToolbox produced output for the latest change.
    ///   - resent: an earlier step of this settle already re-encoded it.
    static func action(
        step: Int,
        delivered: Bool,
        lastOutputBytes: Int,
        previousStepEncoded: Bool,
        resent: Bool,
        keyframeDue: Bool
    ) -> Action {
        if step == keyframeStep && keyframeDue { return .keyframe }
        if !delivered { return .refresh }
        let refining = step == 0
            ? lastOutputBytes >= refineStartBytes
            : previousStepEncoded && lastOutputBytes >= refineContinueBytes
        if refining { return .refresh }
        return step == keyframeStep && !resent ? .refresh : .none
    }

    /// Whether to schedule the step after `step`. Steps up to the keyframe
    /// step always run, so a still screen can still be re-anchored; after it,
    /// the chain continues only while it is delivering or refining.
    static func continues(afterStep step: Int, action: Action) -> Bool {
        guard step + 1 < stepOffsetsNs.count else { return false }
        return step < keyframeStep || action != .none
    }
}
