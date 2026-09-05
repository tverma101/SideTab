import Foundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Early wireless capture-admission gate. It uses ScreenCaptureKit's own change
/// metadata to skip explicitly clean frames and also suppresses routine captures
/// while the video transport is backed up, before pattern/dither/HDR and
/// VideoToolbox work begin. A pending forced IDR always wins over both gates.
enum WirelessDirtyRectGate {
    static func frameHasChanges(_ sampleBuffer: CMSampleBuffer) -> Bool? {
        guard let attachments =
            (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]])?.first,
            let raw = attachments[.dirtyRects]
        else {
            return nil
        }

        if let rects = raw as? [CGRect] {
            return rects.contains { !$0.isNull && !$0.isEmpty }
        }

        // Foundation may bridge CGRect arrays through NSValue depending on the
        // SDK/runtime combination. Treat an explicitly empty array as no change;
        // any unrecognized non-empty payload falls back to encoding.
        if let values = raw as? [NSValue] {
            return values.contains { value in
                let rect = value.rectValue
                return !rect.isNull && !rect.isEmpty
            }
        }

        return nil
    }

    static func shouldSkip(
        wireless: Bool,
        frameHasChanges: Bool?,
        mutatesCapturedPixels: Bool,
        captureAdmission: WirelessTransportPressure.CaptureAdmission = WirelessTransportPressure.captureAdmission
    ) -> Bool {
        guard wireless else { return false }

        // One atomic transport snapshot decides whether this exact captured
        // frame is routine, pressure-gated, or the recovery frame that must pass.
        switch captureAdmission {
        case .forced:
            return false
        case .pause:
            return true
        case .normal:
            break
        }

        guard !mutatesCapturedPixels else { return false }
        return frameHasChanges == false
    }
}
