import Foundation

/// Adaptive encode/send pacing for high-refresh USB sessions.
///
/// ScreenCaptureKit continues capturing at the configured refresh rate (up to
/// 120 Hz), so motion is always sampled at the highest requested cadence. This
/// pacer suppresses frames before VideoToolbox based on two independent signals:
///
/// 1. ScreenCaptureKit dirty metadata reduces clean-screen work:
///      active -> motion target
///      0.15s clean -> up to 60 FPS
///      0.60s clean -> up to 30 FPS
///      2.00s clean -> up to 1 FPS keepalive
/// 2. USBAdaptiveLoadController can constrain *motion* 120 -> 90 -> 60 when
///    sender or downstream recovery pressure is sustained.
///
/// The first changed frame after an idle period always punches through
/// immediately, even when the current motion ceiling is 60/90 FPS.
///
/// The feature defaults on only above 60 Hz so existing 30/60 Hz USB behavior
/// is unchanged. `SideScreen_adaptiveUsbFps` can explicitly enable/disable it.
final class USBAdaptiveFramePacer {
    enum Phase: String, Equatable {
        case bypass
        case active
        case settling
        case idle
        case deepIdle
    }

    struct Decision: Equatable {
        let skip: Bool
        let targetFPS: Int
        let phase: Phase
    }

    static let shared = USBAdaptiveFramePacer()

    private struct State {
        var initialized = false
        var lastChangedNs: UInt64 = 0
        var lastSentNs: UInt64 = 0
        var nextSendDeadlineNs: UInt64 = 0
        var lastTargetFPS = 0
        var forceNext = false
    }

    private let lock = NSLock()
    private var state = State()

    static func configuredMaxFPS(defaults: UserDefaults = .standard) -> Int {
        let experimental = defaults.integer(forKey: "SideScreen_exp_fps")
        if experimental > 0 {
            return clampFPS(experimental)
        }
        if defaults.bool(forKey: "SideScreen_gamingBoost") {
            return 120
        }
        let configured = defaults.integer(forKey: "SideScreen_refreshRate")
        return clampFPS(configured > 0 ? configured : 60)
    }

    static func isEnabled(maxFPS: Int, defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: "SideScreen_adaptiveUsbFps") != nil {
            return defaults.bool(forKey: "SideScreen_adaptiveUsbFps")
        }
        return maxFPS > 60
    }

    private static func clampFPS(_ fps: Int) -> Int {
        min(max(fps, 1), 240)
    }

    func forceNextFrame() {
        lock.lock()
        state.forceNext = true
        lock.unlock()
    }

    func shouldSkip(
        frameHasChanges: Bool?,
        mutatesCapturedPixels: Bool,
        defaults: UserDefaults = .standard,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        let maxFPS = Self.configuredMaxFPS(defaults: defaults)
        let adaptiveEnabled = Self.isEnabled(maxFPS: maxFPS, defaults: defaults)
        let motionTarget = adaptiveEnabled
            ? USBAdaptiveLoadController.shared.motionTargetFPS(maxFPS: maxFPS, nowNs: nowNs)
            : maxFPS
        return decide(
            frameHasChanges: frameHasChanges,
            mutatesCapturedPixels: mutatesCapturedPixels,
            maxFPS: maxFPS,
            adaptiveEnabled: adaptiveEnabled,
            motionTargetFPS: motionTarget,
            nowNs: nowNs
        ).skip
    }

    /// Deterministic entry point used by tests and diagnostics.
    /// `motionTargetFPS` lets tests model the load controller independently.
    func decide(
        frameHasChanges: Bool?,
        mutatesCapturedPixels: Bool,
        maxFPS rawMaxFPS: Int,
        adaptiveEnabled: Bool = true,
        motionTargetFPS rawMotionTargetFPS: Int? = nil,
        nowNs: UInt64
    ) -> Decision {
        let maxFPS = Self.clampFPS(rawMaxFPS)
        let motionTargetFPS = min(
            maxFPS,
            Self.clampFPS(rawMotionTargetFPS ?? maxFPS)
        )

        lock.lock()
        defer { lock.unlock() }

        // Missing dirty metadata must fail open: never guess that a frame is
        // redundant. Synthetic pixel experiments also bypass the pacer because
        // their changes happen after ScreenCaptureKit produced dirty metadata.
        if !adaptiveEnabled || mutatesCapturedPixels || frameHasChanges == nil {
            noteSent(nowNs: nowNs, changed: frameHasChanges != false, targetFPS: maxFPS)
            return Decision(skip: false, targetFPS: maxFPS, phase: .bypass)
        }

        if state.forceNext {
            state.forceNext = false
            noteSent(nowNs: nowNs, changed: frameHasChanges == true, targetFPS: motionTargetFPS)
            return Decision(skip: false, targetFPS: motionTargetFPS, phase: .active)
        }

        // First frame always passes. If it is already clean, treat this moment
        // as the start of the idle timer rather than dropping startup pixels.
        if !state.initialized {
            state.initialized = true
            state.lastChangedNs = nowNs
            noteSent(nowNs: nowNs, changed: frameHasChanges == true, targetFPS: motionTargetFPS)
            return Decision(skip: false, targetFPS: motionTargetFPS, phase: .active)
        }

        let wasIdleBeforeChange = frameHasChanges == true &&
            Self.elapsed(from: state.lastChangedNs, to: nowNs) >= 150_000_000

        if frameHasChanges == true {
            state.lastChangedNs = nowNs
            // Waking an idle desktop is latency-sensitive. A changed frame must
            // not wait behind the previous 1/30/60-FPS clean-frame deadline.
            if wasIdleBeforeChange {
                noteSent(nowNs: nowNs, changed: true, targetFPS: motionTargetFPS)
                return Decision(skip: false, targetFPS: motionTargetFPS, phase: .active)
            }

            let skip = shouldSkipForCadence(targetFPS: motionTargetFPS, maxFPS: maxFPS, nowNs: nowNs)
            if !skip {
                state.lastSentNs = nowNs
            }
            return Decision(skip: skip, targetFPS: motionTargetFPS, phase: .active)
        }

        let idleNs = Self.elapsed(from: state.lastChangedNs, to: nowNs)
        let cleanCeiling: Int
        let phase: Phase
        switch idleNs {
        case ..<150_000_000:
            cleanCeiling = maxFPS
            phase = .active
        case ..<600_000_000:
            cleanCeiling = min(maxFPS, 60)
            phase = .settling
        case ..<2_000_000_000:
            cleanCeiling = min(maxFPS, 30)
            phase = .idle
        default:
            // ScreenCaptureKit explicitly says nothing changed. Keep a very low
            // periodic frame for liveness/stats, but avoid waking VideoToolbox,
            // USB/TCP, and MediaCodec 15 times a second for identical pixels.
            cleanCeiling = 1
            phase = .deepIdle
        }

        let target = min(motionTargetFPS, cleanCeiling)
        let skip = shouldSkipForCadence(targetFPS: target, maxFPS: maxFPS, nowNs: nowNs)
        if !skip {
            state.lastSentNs = nowNs
        }
        return Decision(skip: skip, targetFPS: target, phase: phase)
    }

    func resetForTest() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    /// Deadline-carry pacing is important for 90 FPS on a 120-Hz capture.
    /// A simple "time since last send >= 11.1 ms" gate sees samples every
    /// 8.33 ms and accidentally collapses 90 FPS to ~60. Carrying the ideal
    /// deadline forward produces the intended 3-of-4 cadence instead.
    private func shouldSkipForCadence(targetFPS: Int, maxFPS: Int, nowNs: UInt64) -> Bool {
        if targetFPS >= maxFPS {
            state.lastTargetFPS = targetFPS
            state.nextSendDeadlineNs = nowNs &+ Self.intervalNs(fps: targetFPS)
            return false
        }

        let intervalNs = Self.intervalNs(fps: targetFPS)
        if state.lastTargetFPS != targetFPS || state.nextSendDeadlineNs == 0 {
            state.lastTargetFPS = targetFPS
            state.nextSendDeadlineNs = nowNs &+ intervalNs
            return false
        }

        guard nowNs >= state.nextSendDeadlineNs else { return true }

        var next = state.nextSendDeadlineNs &+ intervalNs
        // Preserve fractional cadence when only slightly late (the normal
        // 120->90 case), but never try to catch up with a burst after a stall.
        if next <= nowNs && Self.elapsed(from: next, to: nowNs) > intervalNs {
            next = nowNs &+ intervalNs
        }
        state.nextSendDeadlineNs = next
        return false
    }

    private func noteSent(nowNs: UInt64, changed: Bool, targetFPS: Int) {
        state.initialized = true
        state.lastSentNs = nowNs
        if changed || state.lastChangedNs == 0 {
            state.lastChangedNs = nowNs
        }
        state.lastTargetFPS = targetFPS
        state.nextSendDeadlineNs = nowNs &+ Self.intervalNs(fps: targetFPS)
    }

    private static func intervalNs(fps: Int) -> UInt64 {
        UInt64(1_000_000_000 / max(1, fps))
    }

    private static func elapsed(from earlier: UInt64, to later: UInt64) -> UInt64 {
        guard later >= earlier else { return 0 }
        return later - earlier
    }
}
