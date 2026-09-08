import Foundation

/// Adaptive encode/send pacing for high-refresh USB sessions.
///
/// ScreenCaptureKit continues capturing at the configured refresh rate (up to
/// 120 Hz), so the first changed frame is always available immediately. This
/// pacer only suppresses redundant clean frames before they reach VideoToolbox,
/// the USB tunnel, and the Android decoder/presenter.
///
/// Policy:
///   - active pixels / unknown dirty metadata -> full configured rate
///   - 0.15s clean -> up to 60 FPS
///   - 0.60s clean -> up to 30 FPS
///   - 2.00s clean -> up to 15 FPS
///   - first changed frame after any idle phase -> immediate full-rate send
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
        decide(
            frameHasChanges: frameHasChanges,
            mutatesCapturedPixels: mutatesCapturedPixels,
            maxFPS: Self.configuredMaxFPS(defaults: defaults),
            adaptiveEnabled: Self.isEnabled(
                maxFPS: Self.configuredMaxFPS(defaults: defaults),
                defaults: defaults
            ),
            nowNs: nowNs
        ).skip
    }

    /// Deterministic entry point used by tests and diagnostics.
    func decide(
        frameHasChanges: Bool?,
        mutatesCapturedPixels: Bool,
        maxFPS rawMaxFPS: Int,
        adaptiveEnabled: Bool = true,
        nowNs: UInt64
    ) -> Decision {
        let maxFPS = Self.clampFPS(rawMaxFPS)

        lock.lock()
        defer { lock.unlock() }

        // Missing dirty metadata must fail open: never guess that a frame is
        // redundant. Synthetic pixel experiments also bypass the pacer because
        // their changes happen after ScreenCaptureKit produced dirty metadata.
        if !adaptiveEnabled || mutatesCapturedPixels || frameHasChanges == nil {
            noteSent(nowNs: nowNs, changed: frameHasChanges != false)
            return Decision(skip: false, targetFPS: maxFPS, phase: .bypass)
        }

        if state.forceNext {
            state.forceNext = false
            noteSent(nowNs: nowNs, changed: frameHasChanges == true)
            return Decision(skip: false, targetFPS: maxFPS, phase: .active)
        }

        // First frame always passes. If it is already clean, treat this moment
        // as the start of the idle timer rather than dropping startup pixels.
        if !state.initialized {
            state.initialized = true
            state.lastChangedNs = nowNs
            state.lastSentNs = nowNs
            return Decision(skip: false, targetFPS: maxFPS, phase: .active)
        }

        // Any actual changed frame bypasses idle pacing immediately. SCK already
        // caps frame production at maxFPS, so no extra active-motion throttle is
        // needed here and input/animation latency stays minimal.
        if frameHasChanges == true {
            state.lastChangedNs = nowNs
            state.lastSentNs = nowNs
            return Decision(skip: false, targetFPS: maxFPS, phase: .active)
        }

        let idleNs = elapsed(from: state.lastChangedNs, to: nowNs)
        let target: Int
        let phase: Phase
        switch idleNs {
        case ..<150_000_000:
            target = maxFPS
            phase = .active
        case ..<600_000_000:
            target = min(maxFPS, 60)
            phase = .settling
        case ..<2_000_000_000:
            target = min(maxFPS, 30)
            phase = .idle
        default:
            target = min(maxFPS, 15)
            phase = .deepIdle
        }

        let intervalNs = UInt64(1_000_000_000 / max(target, 1))
        if elapsed(from: state.lastSentNs, to: nowNs) >= intervalNs {
            state.lastSentNs = nowNs
            return Decision(skip: false, targetFPS: target, phase: phase)
        }

        return Decision(skip: true, targetFPS: target, phase: phase)
    }

    func resetForTest() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    private func noteSent(nowNs: UInt64, changed: Bool) {
        state.initialized = true
        state.lastSentNs = nowNs
        if changed || state.lastChangedNs == 0 {
            state.lastChangedNs = nowNs
        }
    }

    private func elapsed(from earlier: UInt64, to later: UInt64) -> UInt64 {
        guard later >= earlier else { return 0 }
        return later - earlier
    }
}
