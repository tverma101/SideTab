import Foundation

/// Resolves the effective limits for one host streaming session. Keeping this
/// separate from persisted settings prevents a wireless connection from
/// changing the user's USB preferences while still enforcing a safe LAN path.
enum WirelessSessionProfile {
    static func frameRate(for mode: ConnectionMode, requested: Int) -> Int {
        let safeRequested = max(1, requested)
        guard mode == .wireless else { return safeRequested }
        return min(safeRequested, WirelessFreshnessPolicy.targetFrameRate)
    }

    static func bitrateCap(for mode: ConnectionMode) -> Int? {
        mode == .wireless ? WirelessFreshnessPolicy.averageBitrateMbps : nil
    }
}
