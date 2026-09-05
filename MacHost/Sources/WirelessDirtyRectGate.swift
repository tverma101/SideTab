import Foundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// Uses ScreenCaptureKit's own change metadata instead of hashing a 2800x1752
/// pixel buffer. `nil` means the SDK/producer did not provide usable metadata,
/// so callers must encode normally. `false` means the key was present and the
/// frame contains no changed area.
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
        mutatesCapturedPixels: Bool
    ) -> Bool {
        guard wireless, !mutatesCapturedPixels else { return false }
        return frameHasChanges == false
    }
}
