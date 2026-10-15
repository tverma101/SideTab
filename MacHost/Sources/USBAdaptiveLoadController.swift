import Foundation

/// Motion-side adaptive FPS controller for high-refresh USB sessions.
///
/// Primary pressure signals:
///   - multiple Network.framework sends still outstanding before `contentProcessed`
///   - `contentProcessed` taking multiple target-frame intervals
///   - repeated decoder recovery/keyframe pulses in a short window
///   - VideoToolbox submit-to-output time showing a queue of about six frames
///     for a sustained stretch (capture-to-output age as a fallback)
/// Corroborating signal:
///   - a TCP send-queue backlog well beyond one frame
///
/// `NWProtocolTCP.Metadata.availableSendBuffer` is the number of bytes still
/// queued in the kernel send buffer, not free space (0 on an idle socket). It
/// was once read as headroom here, so the healthy empty ADB loopback queue
/// recorded pressure before every frame and the ladder could never climb back
/// up. Apple recommends `contentProcessed` as the live-data pacing point; this
/// controller therefore gives completion timing/backlog more weight than the
/// instantaneous queue depth.
///
/// Host encode-age strikes are tracked separately from transport mild-pressure
/// strikes. A fast network completion must not erase evidence that VideoToolbox
/// itself is falling behind. Conversely, one slow encode followed by a healthy
/// encode resets the encode-age streak so distant outliers do not accumulate.
///
/// Encode pressure means the encoder is falling behind: a queue of about six
/// frames (50 ms at 120 FPS) on every frame for `encodeOverloadPersistNs`. An
/// encoder that cannot keep up builds a queue whose latency only grows. When
/// big motion starts after a still screen, VideoToolbox's rate control
/// overshoots (165-330 Mbps for ~2 s against a 112 Mbps cap) and encode time
/// plateaus at 37-43 ms. It stays flat and the output rate keeps up, so
/// VideoToolbox is pipelining, not queueing; it was as slow at 60 FPS as at 90.
/// The old three-frame (25 ms), two-sample rule turned every motion start into
/// seconds at 60/90 on a path that then encodes 120 FPS at ~7 ms. The age from
/// capture is not used when the encoder time is known: it also carries
/// ScreenCaptureKit delivery delay (spikes to 50-60 ms were seen with the
/// encoder at 9 ms), which dropping frames after capture cannot relieve.
///
/// A single recovery pulse is expected during startup, reconnect, or a decoder
/// reset. MediaCodec starvation, however, produces repeated forced-IDR requests
/// (the Android client throttles forced requests to 200 ms). Three pulses inside
/// one second are therefore treated as strong downstream decoder pressure.
///
/// Explicit recovery also creates an unusually large IDR. A short grace window
/// ignores transport/encode pressure caused by that IDR itself, preventing a
/// normal startup/recovery burst from teaching the controller that 120 FPS is
/// unstable. Recovery-burst pressure is never suppressed by this grace window.
///
/// A new connection gets a longer startup grace in which no pressure moves the
/// ladder. Connect sends a host keyframe, the decoder's own request and often an
/// encoder rebuild after codec negotiation, so its first second looks like both
/// a recovery burst and encode overload on a healthy path.
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
        case encodeAge
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
        let encodeAgeStrikes: Int
        let healthyCompletions: Int
        let rampPenalty: Int
        let lastPressureNs: UInt64
        let recoveryPulseCount: Int
        let transportGraceUntilNs: UInt64
        let startupGraceUntilNs: UInt64
    }

    static let shared = USBAdaptiveLoadController()

    private struct State {
        var generation: UInt64 = 0
        var active = false
        var maxFPS = 60
        var targetFPS = 60
        var mildPressureStrikes = 0
        var encodeAgeStrikes = 0
        /// Start of the current run of over-budget encodes, 0 when none.
        var encodeOverSinceNs: UInt64 = 0
        var healthyCompletions = 0
        var rampPenalty = 0
        var lastPressureNs: UInt64 = 0
        var lastAdjustmentNs: UInt64 = 0
        var lastRampUpNs: UInt64 = 0
        var hasAdjusted = false
        var recoveryPulseCount = 0
        var lastRecoveryPulseNs: UInt64 = 0
        var transportGraceUntilNs: UInt64 = 0
        var startupGraceUntilNs: UInt64 = 0
        var diagnostics = Diagnostics()
    }

    /// Counts since the last periodic summary line.
    private struct Diagnostics {
        var windowStartNs: UInt64 = 0
        var encodedFrames = 0
        var encodeAgeSumNs: UInt64 = 0
        var encodeAgeMaxNs: UInt64 = 0
        var encodeAgeOverThreshold = 0
        var encodeFrames = 0
        var encodeSumNs: UInt64 = 0
        var encodeMaxNs: UInt64 = 0
        var pressure: [PressureKind: Int] = [:]
        var ignoredPressure = 0
    }

    private let lock = NSLock()
    private var state = State()

    private static let downshiftCooldownNs: UInt64 = 250_000_000
    private static let postRampPenaltyWindowNs: UInt64 = 2_000_000_000
    private static let healthyCompletionsForRamp = 12
    private static let mildStrikesForDownshift = 2
    private static let encodeAgeStrikesForDownshift = 2
    private static let encodeOverloadPersistNs: UInt64 = 250_000_000
    private static let maxRampPenalty = 3
    private static let recoveryBurstWindowNs: UInt64 = 1_000_000_000
    private static let recoveryPulsesForDownshift = 3
    private static let keyframeTransportGraceNs: UInt64 = 250_000_000
    private static let minimumEncodeAgePressureNs: UInt64 = 25_000_000
    /// Queued bytes beyond one frame's worth (the frame about to be sent stands
    /// in for the previous one) that count as backlog. The ADB loopback socket
    /// normally reads 0.
    private static let queuedBacklogPressureBytes = 64 * 1024
    private static let diagnosticsIntervalNs: UInt64 = 2_000_000_000
    /// Connect-time keyframes and encoder warm-up are not overload.
    static let startupGraceNs: UInt64 = 3_000_000_000

    /// `startupGraceNs` is 0 by default so deterministic tests start with a
    /// live ladder; production passes `startupGraceNs` with the real clock.
    @discardableResult
    func reset(
        generation: UInt64,
        maxFPS rawMaxFPS: Int,
        startupGraceNs: UInt64 = 0,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Int {
        let maxFPS = Self.clampFPS(rawMaxFPS)
        lock.lock()
        state = State(
            generation: generation,
            active: maxFPS > 60,
            maxFPS: maxFPS,
            targetFPS: maxFPS,
            startupGraceUntilNs: startupGraceNs > 0 ? nowNs &+ startupGraceNs : 0
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
                targetFPS: requestedMax,
                startupGraceUntilNs: state.startupGraceUntilNs
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

    /// `queuedBytes` is sampled just before `frameBytes` is submitted, so it
    /// holds earlier frames the peer has not taken yet.
    func observeSendBuffer(
        generation: UInt64,
        queuedBytes: UInt32,
        frameBytes: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard Int(queuedBytes) - frameBytes > Self.queuedBacklogPressureBytes else { return }
        // Queue depth is corroboration, never a one-sample hard downshift.
        // Healthy contentProcessed completions decay this transport strike.
        recordPressure(
            generation: generation,
            kind: .sendBuffer,
            severity: .mild,
            nowNs: nowNs
        )
    }

    /// Feed capture -> VideoToolbox output age into an independent strike streak.
    /// The callback can be asynchronous, so rising age is direct evidence that
    /// work is spending multiple frame periods inside the host capture/encode
    /// pipeline even when TCP itself is draining normally. Two consecutive
    /// over-budget encoded frames are required before a one-tier downshift.
    /// `ageNs` is capture PTS -> VideoToolbox output. `encodeNs`, when known,
    /// is submit -> output: the encoder's own share of that age.
    func observeEncodedFrameAge(
        ageNs: UInt64,
        encodeNs: UInt64? = nil,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var generation: UInt64 = 0
        var shouldDownshift = false

        lock.lock()
        guard state.active, state.generation != 0 else {
            lock.unlock()
            return
        }

        let latencyNs = encodeNs ?? ageNs
        let summary = noteEncodedFrameLocked(ageNs: ageNs, encodeNs: encodeNs, latencyNs: latencyNs, nowNs: nowNs)
        defer { if let summary { debugLog(summary) } }

        // Recovery IDRs are intentionally large; do not learn host overload from
        // their encode age. Also clear the streak so pre-IDR evidence cannot join
        // with a later unrelated sample after the grace window.
        if nowNs < state.transportGraceUntilNs {
            state.encodeAgeStrikes = 0
            state.encodeOverSinceNs = 0
            lock.unlock()
            return
        }

        guard latencyNs > Self.encodeAgeThresholdNs(fps: state.targetFPS) else {
            state.encodeAgeStrikes = 0
            state.encodeOverSinceNs = 0
            lock.unlock()
            return
        }

        if state.encodeOverSinceNs == 0 { state.encodeOverSinceNs = nowNs }
        state.encodeAgeStrikes = min(state.encodeAgeStrikes + 1, 10_000)
        if state.encodeAgeStrikes >= Self.encodeAgeStrikesForDownshift,
           Self.elapsed(from: state.encodeOverSinceNs, to: nowNs) >= Self.encodeOverloadPersistNs {
            generation = state.generation
            state.encodeAgeStrikes = 0
            state.encodeOverSinceNs = 0
            shouldDownshift = true
        }
        lock.unlock()

        if shouldDownshift {
            recordPressure(
                generation: generation,
                kind: .encodeAge,
                severity: .severe,
                nowNs: nowNs
            )
        }
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

        // A forced IDR is much larger than a routine P-frame. Ignore transport
        // or encode-age pressure caused by that intentional burst for a bounded
        // interval. A repeated recovery burst still downshifts below.
        let graceDeadline = nowNs &+ Self.keyframeTransportGraceNs
        if graceDeadline > state.transportGraceUntilNs {
            state.transportGraceUntilNs = graceDeadline
        }
        state.encodeAgeStrikes = 0
        state.encodeOverSinceNs = 0

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
            // Network health only decays network-derived mild pressure. It must
            // not erase a VideoToolbox encode-age streak.
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
            encodeAgeStrikes: state.encodeAgeStrikes,
            healthyCompletions: state.healthyCompletions,
            rampPenalty: state.rampPenalty,
            lastPressureNs: state.lastPressureNs,
            recoveryPulseCount: state.recoveryPulseCount,
            transportGraceUntilNs: state.transportGraceUntilNs,
            startupGraceUntilNs: state.startupGraceUntilNs
        )
    }

    /// Accumulates one encoded frame and, every couple of seconds, returns a
    /// summary line for the caller to log once the lock is released.
    private func noteEncodedFrameLocked(ageNs: UInt64, encodeNs: UInt64?, latencyNs: UInt64, nowNs: UInt64) -> String? {
        if state.diagnostics.windowStartNs == 0 { state.diagnostics.windowStartNs = nowNs }
        if let encodeNs {
            state.diagnostics.encodeFrames += 1
            state.diagnostics.encodeSumNs &+= encodeNs
            state.diagnostics.encodeMaxNs = max(state.diagnostics.encodeMaxNs, encodeNs)
        }
        state.diagnostics.encodedFrames += 1
        state.diagnostics.encodeAgeSumNs &+= ageNs
        state.diagnostics.encodeAgeMaxNs = max(state.diagnostics.encodeAgeMaxNs, ageNs)
        if latencyNs > Self.encodeAgeThresholdNs(fps: state.targetFPS) {
            state.diagnostics.encodeAgeOverThreshold += 1
        }
        guard Self.elapsed(from: state.diagnostics.windowStartNs, to: nowNs) >= Self.diagnosticsIntervalNs else {
            return nil
        }
        let d = state.diagnostics
        state.diagnostics = Diagnostics(windowStartNs: nowNs)
        let pressure = [PressureKind.sendBacklog, .sendBuffer, .slowSend, .encodeAge, .recoveryBurst]
            .map { "\($0.rawValue)=\(d.pressure[$0, default: 0])" }
            .joined(separator: " ")
        let avgMs = Double(d.encodeAgeSumNs) / Double(max(1, d.encodedFrames)) / 1_000_000
        let vtAvgMs = Double(d.encodeSumNs) / Double(max(1, d.encodeFrames)) / 1_000_000
        return "USB adaptive: target=\(state.targetFPS) frames=\(d.encodedFrames) " +
            String(format: "encodeAge avg=%.1fms max=%.1fms ", avgMs, Double(d.encodeAgeMaxNs) / 1_000_000) +
            String(format: "vt avg=%.1fms max=%.1fms n=%d ", vtAvgMs, Double(d.encodeMaxNs) / 1_000_000, d.encodeFrames) +
            "over=\(d.encodeAgeOverThreshold) pressure: \(pressure) ignored=\(d.ignoredPressure) " +
            "healthy=\(state.healthyCompletions) penalty=\(state.rampPenalty)"
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

        // Nothing moves the ladder while a new connection settles.
        if nowNs < state.startupGraceUntilNs {
            state.diagnostics.ignoredPressure += 1
            return
        }

        // A large forced IDR can transiently look like network or encode
        // congestion. Do not let that expected burst alter the motion tier.
        // Decoder-recovery bursts are a separate signal and bypass this guard.
        if kind != .recoveryBurst && nowNs < state.transportGraceUntilNs {
            state.diagnostics.ignoredPressure += 1
            return
        }
        state.diagnostics.pressure[kind, default: 0] += 1

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
            state.encodeAgeStrikes = 0
            state.encodeOverSinceNs = 0
            stepDownIfAllowed(kind: kind, nowNs: nowNs)
        case .mild:
            state.mildPressureStrikes = min(
                Self.mildStrikesForDownshift,
                state.mildPressureStrikes + 1
            )
            if state.mildPressureStrikes >= Self.mildStrikesForDownshift {
                if stepDownIfAllowed(kind: kind, nowNs: nowNs) {
                    state.mildPressureStrikes = 0
                    state.encodeAgeStrikes = 0
                    state.encodeOverSinceNs = 0
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
        state.mildPressureStrikes = 0
        state.encodeAgeStrikes = 0
        state.encodeOverSinceNs = 0
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
        state.encodeAgeStrikes = 0
        state.encodeOverSinceNs = 0
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

    private static func encodeAgeThresholdNs(fps: Int) -> UInt64 {
        max(minimumEncodeAgePressureNs, intervalNs(fps: fps) &* 6)
    }

    private static func elapsed(from earlier: UInt64, to later: UInt64) -> UInt64 {
        guard later >= earlier else { return 0 }
        return later - earlier
    }
}
