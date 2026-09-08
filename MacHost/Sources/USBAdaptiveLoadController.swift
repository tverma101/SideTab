import Foundation

/// Motion-side adaptive FPS controller for high-refresh USB sessions.
///
/// Primary pressure signals:
///   - multiple Network.framework sends still outstanding before `contentProcessed`
///   - `contentProcessed` taking multiple target-frame intervals
///   - repeated decoder recovery/keyframe pulses in a short window
/// Corroborating signal:
///   - TCP send-buffer headroom becoming critically small
///
/// Network.framework can accept a message larger than the currently available
/// kernel send buffer, so frameBytes > availableSendBuffer is NOT by itself
/// evidence of congestion. Apple recommends `contentProcessed` as the live-data
/// pacing point; this controller therefore gives completion timing/backlog more
/// weight than instantaneous send-buffer capacity.
///
/// A single recovery pulse is expected during startup, reconnect, or a decoder
/// reset. MediaCodec starvation, however, produces repeated forced-IDR requests
/// (the Android client throttles forced requests to 200 ms). Three pulses inside
/// one second are therefore treated as strong downstream decoder pressure.
///
/// The policy is intentionally asymmetric: congestion falls back quickly,
/// while recovery is slower and requires healthy completions. That hysteresis
/// prevents a marginal 120-Hz path from bouncing 120 <-> 90 every few frames.
///
/// The transport generation is supplied by WirelessTransportPressure (despite
/// that historical type name it owns both USB and Wi-Fi send accounting). Old
/// callbacks from a replaced connection therefore cannot perturb a new USB
/// session.
final class USBAdaptiveLoadController {
    enum PressureKind: String, Equatable {
        case sendBacklog
        case sendBuffer
        case slowSend
        case recoveryBurst
    }

    enum Severity {
        case mild
        case severe
    }

    struct Snapshot: Equatable {
        let generation: UInt64
        let active: Bool
        let maxFPS: Int
        let targetFPS: Int
        let mildPressureStrikes: Int
        let healthyCompletions: Int
        let rampPenalty: Int
        let lastPressureNs: UInt64
        let recoveryPulseCount: Int
    }

    static let shared = USBAdaptiveLoadController()

    private struct State {
        var generation: UInt64 = 0
        var active = false
        var maxFPS = 60
        var targetFPS = 60
        var mildPressureStrikes = 0
        var healthyCompletions = 0
        var rampPenalty = 0
        var lastPressureNs: UInt64 = 0
        var lastAdjustmentNs: UInt64 = 0
        var lastRampUpNs: UInt64 = 0
        var hasAdjusted = false
        var recoveryPulseCount = 0
        var lastRecoveryPulseNs: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()

    private static let downshiftCooldownNs: UInt64 = 250_000_000
    private static let postRampPenaltyWindowNs: UInt64 = 2_000_000_000
    private static let healthyCompletionsForRamp = 12
    private static let mildStrikesForDownshift = 2
    private static let maxRampPenalty = 3
    private static let recoveryBurstWindowNs: UInt64 = 1_000_000_000
    private static let recoveryPulsesForDownshift = 3
    /// Only near-exhaustion is meaningful. A large frame may legitimately be
    /// bigger than the whole TCP send buffer and Network.framework will drain it
    /// asynchronously; comparing headroom to frame size would false-trigger.
    private static let criticallyLowSendHeadroomBytes = 32 * 1024

    @discardableResult
    func reset(generation: UInt64, maxFPS rawMaxFPS: Int) -> Int {
        let maxFPS = Self.clampFPS(rawMaxFPS)
        lock.lock()
        state = State(
            generation: generation,
            active: maxFPS > 60,
            maxFPS: maxFPS,
            targetFPS: maxFPS
        )
        lock.unlock()
        return maxFPS
    }

    func retire(generation: UInt64) {
        lock.lock()
        if state.generation == generation {
            state = State()
        }
        lock.unlock()
    }

    /// Retire whichever USB generation is active. Used when the single video
    /// transport switches to Wi-Fi.
    func retireCurrent() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    /// Current motion target, with a possible cautious ramp-up when the path has
    /// remained healthy long enough. Call from the frame pacer on changed frames.
    func motionTargetFPS(
        maxFPS rawMaxFPS: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Int {
        let requestedMax = Self.clampFPS(rawMaxFPS)
        lock.lock()
        defer { lock.unlock() }

        guard state.generation != 0 else { return requestedMax }

        // Settings can change while the USB connection stays alive. Starting a
        // fresh ladder at the newly requested ceiling is safer than carrying a
        // 60/90 decision that was learned for a different source cadence.
        if state.maxFPS != requestedMax {
            let generation = state.generation
            state = State(
                generation: generation,
                active: requestedMax > 60,
                maxFPS: requestedMax,
                targetFPS: requestedMax
            )
            debugLog("USB adaptive FPS: source ceiling changed -> \(requestedMax), controller reset")
        }

        guard state.active else { return requestedMax }
        maybeRampUp(nowNs: nowNs)
        return state.targetFPS
    }

    func observeSendsInFlight(
        generation: UInt64,
        count: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard count >= 2 else { return }
        recordPressure(
            generation: generation,
            kind: .sendBacklog,
            severity: count >= 3 ? .severe : .mild,
            nowNs: nowNs
        )
    }

    func observeSendBuffer(
        generation: UInt64,
        availableBytes: UInt32,
        frameBytes _: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard Int(availableBytes) < Self.criticallyLowSendHeadroomBytes else { return }
        // Headroom is corroboration, never a one-sample hard downshift. Healthy
        // contentProcessed completions decay this strike again.
        recordPressure(
            generation: generation,
            kind: .sendBuffer,
            severity: .mild,
            nowNs: nowNs
        )
    }

    /// Observe a host keyframe/recovery pulse. One or two pulses can be normal
    /// startup/reset traffic. Three pulses inside the burst window are a strong
    /// signal that the client is repeatedly losing decoder continuity or input
    /// buffers, so step down one motion tier. The burst counter resets after a
    /// downshift so sustained trouble must provide fresh evidence for 90 -> 60.
    func observeRecoveryPulse(
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var generation: UInt64 = 0
        var shouldDownshift = false

        lock.lock()
        guard state.active, state.generation != 0 else {
            lock.unlock()
            return
        }

        if state.lastRecoveryPulseNs == 0 ||
            Self.elapsed(from: state.lastRecoveryPulseNs, to: nowNs) > Self.recoveryBurstWindowNs {
            state.recoveryPulseCount = 1
        } else {
            state.recoveryPulseCount = min(
                Self.recoveryPulsesForDownshift,
                state.recoveryPulseCount + 1
            )
        }
        state.lastRecoveryPulseNs = nowNs

        if state.recoveryPulseCount >= Self.recoveryPulsesForDownshift {
            generation = state.generation
            state.recoveryPulseCount = 0
            shouldDownshift = true
        }
        lock.unlock()

        if shouldDownshift {
            recordPressure(
                generation: generation,
                kind: .recoveryBurst,
                severity: .severe,
                nowNs: nowNs
            )
        }
    }

    /// `durationNs` is beginSend -> Network.framework `contentProcessed`.
    /// Apple defines that completion as the point where the stack consumed the
    /// data, so a duration several target-frame intervals long means the
    /// producer is outrunning local transport submission even on ADB loopback.
    func observeSendCompletion(
        generation: UInt64,
        durationNs: UInt64,
        sendsInFlightAfter: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        guard state.active, state.generation == generation else {
            lock.unlock()
            return
        }

        let intervalNs = Self.intervalNs(fps: state.targetFPS)
        let slowThresholdNs = max(20_000_000, intervalNs &* 2)
        let healthyThresholdNs = intervalNs + intervalNs / 2
        let isSlow = durationNs > slowThresholdNs
        let isHealthy = !isSlow && sendsInFlightAfter == 0 && durationNs <= healthyThresholdNs

        if isHealthy {
            state.healthyCompletions = min(state.healthyCompletions + 1, 10_000)
            if state.mildPressureStrikes > 0 {
                state.mildPressureStrikes -= 1
            }
            lock.unlock()
            return
        }
        lock.unlock()

        if isSlow {
            recordPressure(
                generation: generation,
                kind: .slowSend,
                severity: sendsInFlightAfter >= 2 ? .severe : .mild,
                nowNs: nowNs
            )
        }
    }

    func snapshotForTest() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            generation: state.generation,
            active: state.active,
            maxFPS: state.maxFPS,
            targetFPS: state.targetFPS,
            mildPressureStrikes: state.mildPressureStrikes,
            healthyCompletions: state.healthyCompletions,
            rampPenalty: state.rampPenalty,
            lastPressureNs: state.lastPressureNs,
            recoveryPulseCount: state.recoveryPulseCount
        )
    }

    private func recordPressure(
        generation: UInt64,
        kind: PressureKind,
        severity: Severity,
        nowNs: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard state.active, state.generation == generation else { return }

        state.lastPressureNs = nowNs
        state.healthyCompletions = 0

        if state.lastRampUpNs > 0,
           Self.elapsed(from: state.lastRampUpNs, to: nowNs) < Self.postRampPenaltyWindowNs {
            state.rampPenalty = min(Self.maxRampPenalty, state.rampPenalty + 1)
            state.lastRampUpNs = 0 // one penalty per failed ramp attempt
        }

        switch severity {
        case .severe:
            state.mildPressureStrikes = 0
            stepDownIfAllowed(kind: kind, nowNs: nowNs)
        case .mild:
            state.mildPressureStrikes = min(
                Self.mildStrikesForDownshift,
                state.mildPressureStrikes + 1
            )
            if state.mildPressureStrikes >= Self.mildStrikesForDownshift {
                if stepDownIfAllowed(kind: kind, nowNs: nowNs) {
                    state.mildPressureStrikes = 0
                }
            }
        }
    }

    @discardableResult
    private func stepDownIfAllowed(kind: PressureKind, nowNs: UInt64) -> Bool {
        let levels = Self.levels(maxFPS: state.maxFPS)
        guard let index = levels.firstIndex(of: state.targetFPS), index > 0 else {
            return false
        }

        if state.hasAdjusted,
           Self.elapsed(from: state.lastAdjustmentNs, to: nowNs) < Self.downshiftCooldownNs {
            return false
        }

        let old = state.targetFPS
        state.targetFPS = levels[index - 1]
        state.lastAdjustmentNs = nowNs
        state.hasAdjusted = true
        debugLog("USB adaptive FPS: \(old) -> \(state.targetFPS) (pressure=\(kind.rawValue), penalty=\(state.rampPenalty))")
        return true
    }

    private func maybeRampUp(nowNs: UInt64) {
        let levels = Self.levels(maxFPS: state.maxFPS)
        guard let index = levels.firstIndex(of: state.targetFPS), index + 1 < levels.count else {
            // A long stable run at the ceiling forgives one prior failed probe.
            if state.rampPenalty > 0,
               state.lastPressureNs > 0,
               Self.elapsed(from: state.lastPressureNs, to: nowNs) >= 20_000_000_000 {
                state.rampPenalty -= 1
                state.lastPressureNs = nowNs
            }
            return
        }
        guard state.healthyCompletions >= Self.healthyCompletionsForRamp else { return }

        let baseDelayNs: UInt64 = state.targetFPS <= 60
            ? 2_000_000_000
            : 5_000_000_000
        let multiplier = UInt64(1 << min(Self.maxRampPenalty, state.rampPenalty))
        let requiredDelay = baseDelayNs &* multiplier
        let sincePressure = state.lastPressureNs == 0
            ? UInt64.max
            : Self.elapsed(from: state.lastPressureNs, to: nowNs)
        let sinceAdjustment = state.hasAdjusted
            ? Self.elapsed(from: state.lastAdjustmentNs, to: nowNs)
            : UInt64.max
        guard sincePressure >= requiredDelay, sinceAdjustment >= requiredDelay else { return }

        let old = state.targetFPS
        state.targetFPS = levels[index + 1]
        state.lastAdjustmentNs = nowNs
        state.lastRampUpNs = nowNs
        state.hasAdjusted = true
        state.healthyCompletions = 0
        state.mildPressureStrikes = 0
        debugLog("USB adaptive FPS: \(old) -> \(state.targetFPS) (healthy ramp, penalty=\(state.rampPenalty))")
    }

    private static func levels(maxFPS: Int) -> [Int] {
        Array(Set([min(60, maxFPS), min(90, maxFPS), maxFPS])).sorted()
    }

    private static func clampFPS(_ fps: Int) -> Int {
        min(max(fps, 1), 240)
    }

    private static func intervalNs(fps: Int) -> UInt64 {
        UInt64(1_000_000_000 / max(1, fps))
    }

    private static func elapsed(from earlier: UInt64, to later: UInt64) -> UInt64 {
        guard later >= earlier else { return 0 }
        return later - earlier
    }
}
