import Foundation

/// Periodic safety-keyframe policy. Explicit decoder/startup recovery always
/// forces an IDR immediately; this controls only the routine periodic fallback.
enum EncoderGOPPolicy {
    static func safetySeconds(
        isWireless: Bool,
        frameRate: Int,
        adaptiveUSBEnabled: Bool
    ) -> Int {
        if isWireless { return 5 }
        if adaptiveUSBEnabled && frameRate > 60 { return 5 }
        return 1
    }
}
