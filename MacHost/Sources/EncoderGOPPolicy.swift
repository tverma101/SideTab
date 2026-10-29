import Foundation

/// Periodic safety-keyframe policy. Explicit decoder/startup recovery always
/// forces an IDR immediately; this controls only the routine periodic fallback.
enum EncoderGOPPolicy {
    /// Wi-Fi refreshes its keyframe when motion stops (see
    /// `wirelessIdleKeyframeMinAgeNs`), so the periodic IDR only matters during
    /// long unbroken motion. A 2800x1752 IDR is ~900 KB and stalls the link for
    /// 46-80 ms, which showed up as a dip and dropped frames every 5 s.
    static let wirelessSafetySeconds = 30

    /// The settle refresh promotes one step to an IDR once the last keyframe
    /// is at least this old, so the routine keyframe lands on a still screen
    /// just before the periodic fallback would force one mid-motion. It was
    /// 5 s; light desktop use then sent a ~430-880 KB IDR every ~7 s, each
    /// stalling a weak link for 0.4-1.3 s, and an IDR on a still screen comes
    /// out softer than the refined P-frames it replaces (measured 2026-10-09).
    static let wirelessIdleKeyframeMinAgeNs: UInt64 = 25_000_000_000

    static func safetySeconds(
        isWireless: Bool,
        frameRate: Int,
        adaptiveUSBEnabled: Bool
    ) -> Int {
        if isWireless { return wirelessSafetySeconds }
        if adaptiveUSBEnabled && frameRate > 60 { return 5 }
        return 1
    }
}
