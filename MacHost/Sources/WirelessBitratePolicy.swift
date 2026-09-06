import Foundation

/// Pure state machine for wireless bitrate adaptation. It intentionally reacts
/// to SideScreen's own *capture-pressure* signal rather than raw RTT: pressure
/// means the transport gate had to suppress future work to preserve freshness.
///
/// One noisy window never changes bitrate. Sustained pressure must survive two
/// complete telemetry windows before one downward step; recovery takes five
/// healthy windows before one upward step. This asymmetry prevents quality
/// pumping on ordinary Wi-Fi jitter or periodic IDRs.
struct WirelessBitratePolicy {
    struct Window {
        let completionSamples: Int
        let capturePauseDecisions: Int
        let headroomMinBytes: UInt32?
    }

    private(set) var stepDown = 0
    private(set) var pressuredWindows = 0
    private(set) var healthyWindows = 0

    private static let minimumWindowCompletions = 60
    private static let moderateLowHeadroomBytes: UInt32 = 64 * 1024
    private static let healthyHeadroomBytes: UInt32 = 128 * 1024
    private static let pressureWindowsRequired = 2
    private static let healthyWindowsRequired = 5
    private static let maximumStepDown = 6

    // Same bounded bitrate ladder VideoEncoder uses for wireless quality.
    static let bitrateLadderMbps = [6, 12, 20, 30, 40, 50, 60]

    mutating func reset() {
        stepDown = 0
        pressuredWindows = 0
        healthyWindows = 0
    }

    /// Consume one completed telemetry window and return the current downward
    /// ladder step. Windows smaller than 60 completed sends are ignored so an
    /// idle/static desktop cannot accidentally retune the encoder.
    @discardableResult
    mutating func observe(_ window: Window) -> Int {
        guard window.completionSamples >= Self.minimumWindowCompletions else {
            return stepDown
        }

        // At the normal 120-send telemetry window this is 15 pressure decisions
        // (~12.5%). A low TCP-headroom sample lowers the secondary threshold to
        // eight decisions, but still requires a second consecutive bad window.
        let pauseThreshold = max(12, window.completionSamples / 8)
        let lowHeadroom = window.headroomMinBytes.map { $0 < Self.moderateLowHeadroomBytes } ?? false
        let pressured =
            window.capturePauseDecisions >= pauseThreshold ||
            (lowHeadroom && window.capturePauseDecisions >= 8)

        let healthyHeadroom =
            window.headroomMinBytes.map { $0 >= Self.healthyHeadroomBytes } ?? true
        let healthy = window.capturePauseDecisions <= 2 && healthyHeadroom

        if pressured {
            pressuredWindows += 1
            healthyWindows = 0
            if pressuredWindows >= Self.pressureWindowsRequired {
                stepDown = min(Self.maximumStepDown, stepDown + 1)
                pressuredWindows = 0
            }
            return stepDown
        }

        pressuredWindows = 0
        if healthy {
            healthyWindows += 1
            if healthyWindows >= Self.healthyWindowsRequired {
                stepDown = max(0, stepDown - 1)
                healthyWindows = 0
            }
        } else {
            healthyWindows = 0
        }
        return stepDown
    }

    /// Map a selected wireless quality target to a lower rung. Experiments with
    /// arbitrary bitrate overrides do not use this policy; normal production
    /// targets are exact members of the quality ladder.
    static func targetMbps(baseTargetMbps: Int, stepDown: Int) -> Int {
        guard let baseIndex = bitrateLadderMbps.firstIndex(of: baseTargetMbps) else {
            return baseTargetMbps
        }
        let targetIndex = max(0, baseIndex - max(0, stepDown))
        return bitrateLadderMbps[targetIndex]
    }
}
