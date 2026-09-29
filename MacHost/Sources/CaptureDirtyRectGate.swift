import Foundation
import CoreMedia
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Uses ScreenCaptureKit's own change metadata instead of hashing a 2800x1752
/// pixel buffer. `nil` means the SDK/producer did not provide usable metadata,
/// so callers must encode normally. `false` means the key was present and the
/// frame contains no changed area.
///
/// Constraint worth knowing before trusting `false` right after a restart:
/// ScreenCaptureKit does not apply a correct attachment after
/// `updateConfiguration` (documented in WebRTC's screen_capturer_sck), so the
/// metadata can be stale for the first frames of a new configuration. The host
/// covers that by requesting a keyframe from the freshly built encoder before
/// restarting the stream, which forces at least one real encode per restart.
enum CaptureDirtyRectGate {
    private static let telemetryLock = NSLock()
    /// Frames whose dirty-rect attachment could not be decoded into rects at
    /// all. Without this, a silently dead optimization is indistinguishable
    /// from one that is correctly reporting "no change".
    private(set) static var unknownRepresentationCount = 0
    private(set) static var lastUnknownRepresentation: String?

    static func resetTelemetry() {
        telemetryLock.lock()
        unknownRepresentationCount = 0
        lastUnknownRepresentation = nil
        telemetryLock.unlock()
    }

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

        // The real attachment is a CFArray of CFDictionary rects — this is how
        // Chromium's production screen_capturer_sck.mm reads it, with
        // CGRectMakeWithDictionaryRepresentation. Apple's published header text
        // is stale, and for that representation BOTH `as? [CGRect]` and
        // `as? [NSValue]` return false, which made this gate answer nil
        // (never skip) for EVERY frame.
        if let rects = decodeDictionaryRects(raw) {
            return rects.contains { !$0.isNull && !$0.isEmpty }
        }

        if let rects = raw as? [CGRect] {
            return rects.contains { !$0.isNull && !$0.isEmpty }
        }

        // Foundation may bridge CGRect arrays through NSValue on other
        // SDK/runtime combinations. An explicitly empty array is an
        // unambiguous "nothing changed". Anything else must be provably rects:
        // NSNumber also bridges to NSValue, so a payload of numbers would
        // otherwise decode to zero rects and be reported as clean — a silently
        // frozen screen.
        if let values = raw as? [NSValue] {
            if values.isEmpty { return false }
            guard !values.contains(where: { $0 is NSNumber }) else {
                recordUnknownRepresentation(raw)
                return nil
            }
            return values.contains { value in
                let rect = value.rectValue
                return !rect.isNull && !rect.isEmpty
            }
        }

        recordUnknownRepresentation(raw)
        return nil
    }

    static func shouldSkip(
        frameHasChanges: Bool?,
        mutatesCapturedPixels: Bool
    ) -> Bool {
        guard !mutatesCapturedPixels else { return false }
        return frameHasChanges == false
    }

    /// nil when the payload is not the dictionary representation.
    private static func decodeDictionaryRects(_ raw: Any) -> [CGRect]? {
        // `as? NSArray` rather than `as? CFArray`: the latter is an
        // unconditional success for Any, so it would claim payloads that are
        // not arrays at all.
        guard let elements = raw as? NSArray else { return nil }
        let array = elements as CFArray
        let count = CFArrayGetCount(array)
        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let element = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            // CGRectMakeWithDictionaryRepresentation sends objectForKey: to
            // whatever it is handed, so a non-dictionary element raises an
            // NSInvalidArgumentException instead of returning false. The type
            // has to be checked before the call, never after.
            guard CFGetTypeID(element) == CFDictionaryGetTypeID() else { return nil }
            let dictionary = unsafeBitCast(element, to: CFDictionary.self)
            var rect = CGRect.zero
            // One undecodable element must not be mistaken for "clean".
            guard CGRectMakeWithDictionaryRepresentation(dictionary, &rect) else { return nil }
            rects.append(rect)
        }
        return rects
    }

    private static func recordUnknownRepresentation(_ raw: Any) {
        let description = String(describing: type(of: raw))
        telemetryLock.lock()
        unknownRepresentationCount += 1
        let isNewKind = lastUnknownRepresentation != description
        lastUnknownRepresentation = description
        let total = unknownRepresentationCount
        telemetryLock.unlock()
        // One line per distinct representation keeps the dead-gate signal
        // visible in the log without flooding it.
        if isNewKind || total % 1_000 == 0 {
            debugLog("Dirty-rect gate: unrecognized dirtyRects representation \(description) (\(total) frames) — dirty-rect skipping is inactive")
        }
    }
}
