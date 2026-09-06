import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples TCP send-buffer headroom; capture/VideoEncoder
/// consult the gate before doing routine work. Forced keyframes bypass it.
enum WirelessTransportPressure {
    enum CaptureAdmission: Equatable {
        case normal
        case pause
        case forced
    }

    private struct State {
        var generation: UInt64 = 0
        var wireless = false
        var ready = false
        var sendsInFlight = 0
        var pauseUntilNs: UInt64 = 0
        var lastAvailableSendBuffer: UInt32?
        var forcedCapturePending = false
        var largeSendOutstanding = false

        // Lightweight transport telemetry. Outstanding sends are intentionally
        // tiny (the pressure high-watermark is two), so a fixed pair avoids a
        // per-frame Array append/remove allocation on the 60/90/120 Hz path.
        var oldestSendStartedNs: UInt64 = 0
        var newestSendStartedNs: UInt64 = 0
        var completionSamples = 0
        var completionTotalNs: UInt64 = 0
        var completionMaxNs: UInt64 = 0
        var headroomSamples = 0
        var headroomTotalBytes: UInt64 = 0
        var headroomMinBytes: UInt32?
        var capturePauseDecisions = 0
        var captureForcedDecisions = 0
    }

    private static let lock = NSLock()
    private static var state = State()
    private static let highWatermark = 2
    private static let minimumHeadroomBytes = 32 * 1024
    // A 256 KiB frame is already ~23 ms of payload at the wireless encoder's
    // 90 Mbps hard burst ceiling and occupies most of Android's requested
    // 384 KiB receive window. Do not immediately manufacture another routine
    // dependent frame behind it; wait for the outstanding send set to drain.
    private static let largeSendBytes = 256 * 1024
    private static let sendBufferPauseNs: UInt64 = 20_000_000
    private static let telemetryLogEveryCompletions = 120

    /// Start a new video transport generation and return its pressure token.
    @discardableResult
    static func reset(wireless: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.wireless = wireless
        state.ready = false
        state.sendsInFlight = 0
        state.pauseUntilNs = 0
        state.lastAvailableSendBuffer = nil
        state.forcedCapturePending = false
        state.largeSendOutstanding = false
        resetTelemetryLocked()
        return state.generation
    }

    static func setReady(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.ready = true
    }

    static func beginSend(
        generation: UInt64,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation, state.ready else { return }
        state.sendsInFlight += 1

        // Two timestamp slots are enough because normal capture is gated at two
        // outstanding sends. Forced recovery may briefly exceed that count; in
        // that rare case the newest timestamp still gives a useful lower-bound
        // completion sample without allocating a queue.
        if state.oldestSendStartedNs == 0 {
            state.oldestSendStartedNs = nowNs
        } else {
            state.newestSendStartedNs = nowNs
        }
    }

    static func completeSend(
        generation: UInt64,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var logLine: String?

        lock.lock()
        guard state.generation == generation else {
            lock.unlock()
            return
        }

        let startedNs = state.oldestSendStartedNs
        if startedNs > 0, nowNs >= startedNs {
            let elapsed = nowNs - startedNs
            state.completionSamples += 1
            state.completionTotalNs &+= elapsed
            if elapsed > state.completionMaxNs {
                state.completionMaxNs = elapsed
            }
        }

        state.oldestSendStartedNs = state.newestSendStartedNs
        state.newestSendStartedNs = 0
        state.sendsInFlight = max(0, state.sendsInFlight - 1)
        // observeSendBuffer runs immediately before beginSend. Once every send
        // that was outstanding at/after a large frame has completed, the large
        // payload can no longer be sitting in our local Network.framework queue.
        if state.sendsInFlight == 0 {
            state.largeSendOutstanding = false
            state.oldestSendStartedNs = 0
            state.newestSendStartedNs = 0
        }

        if state.wireless,
           state.completionSamples >= telemetryLogEveryCompletions {
            logLine = telemetryLineLocked()
            resetTelemetryCountersLocked()
        }
        lock.unlock()

        if let logLine {
            debugLog(logLine)
        }
    }

    /// Mark that a recovery/startup IDR must be admitted even when routine
    /// wireless capture is currently pressure-gated. The returned generation
    /// lets VideoEncoder clear only the marker it created; a late encode from an
    /// older transport can never clear a newer session's recovery admission.
    @discardableResult
    static func noteForcedCapturePending() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard state.wireless else { return nil }
        state.forcedCapturePending = true
        return state.generation
    }

    static func clearForcedCapturePending(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.forcedCapturePending = false
    }

    /// One coherent capture-time snapshot. This replaces separate pressure and
    /// forced-keyframe reads, so a concurrent recovery request cannot produce a
    /// contradictory decision for the same captured frame.
    static var captureAdmission: CaptureAdmission {
        captureAdmission(at: DispatchTime.now().uptimeNanoseconds)
    }

    static func captureAdmission(at nowNs: UInt64) -> CaptureAdmission {
        lock.lock()
        defer { lock.unlock() }
        guard state.wireless, state.ready else { return .normal }
        if state.forcedCapturePending {
            state.captureForcedDecisions += 1
            return .forced
        }
        if state.sendsInFlight >= highWatermark ||
            state.largeSendOutstanding ||
            nowNs < state.pauseUntilNs {
            state.capturePauseDecisions += 1
            return .pause
        }
        return .normal
    }

    /// Sample real TCP sender headroom before submitting an encoded frame.
    ///
    /// `availableSendBuffer` describes capacity *before* this frame is handed to
    /// Network.framework. Predict the residual headroom after the frame too.
    /// Preserve enough room for roughly one more frame of comparable size (with
    /// a 32 KiB floor), rather than a fixed tiny reserve that becomes ineffective
    /// at the 30–60 Mbps wireless quality tiers.
    ///
    /// A single unusually large frame also creates pressure until all currently
    /// outstanding video sends drain. This specifically prevents a large IDR or
    /// motion spike from being followed immediately by another routine encode
    /// merely because frame-count pressure has not reached two yet.
    static func observeSendBuffer(
        generation: UInt64,
        availableBytes: UInt32,
        frameBytes: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation, state.wireless, state.ready else { return }

        state.lastAvailableSendBuffer = availableBytes
        state.headroomSamples += 1
        state.headroomTotalBytes &+= UInt64(availableBytes)
        if let minimum = state.headroomMinBytes {
            if availableBytes < minimum {
                state.headroomMinBytes = availableBytes
            }
        } else {
            state.headroomMinBytes = availableBytes
        }

        let available = UInt64(availableBytes)
        let frame = UInt64(max(1, frameBytes))
        let residual = available > frame ? available - frame : 0
        let reserve = max(UInt64(minimumHeadroomBytes), frame)
        let lowHeadroom = available < frame || residual < reserve

        if frameBytes >= largeSendBytes {
            state.largeSendOutstanding = true
        }

        if lowHeadroom {
            let deadline = nowNs &+ sendBufferPauseNs
            if deadline > state.pauseUntilNs {
                state.pauseUntilNs = deadline
            }
        } else {
            // Fresh evidence that this frame still leaves room for another
            // similarly-sized frame should release an older buffer-pressure hold
            // immediately. Send-count and large-payload pressure remain separate.
            state.pauseUntilNs = 0
        }
    }

    static func retire(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.generation &+= 1
        state.ready = false
        state.sendsInFlight = 0
        state.pauseUntilNs = 0
        state.lastAvailableSendBuffer = nil
        state.forcedCapturePending = false
        state.largeSendOutstanding = false
        state.wireless = false
        resetTelemetryLocked()
    }

    /// Routine captures are suppressed only before VideoToolbox sees them.
    /// This keeps H.264/HEVC reference chains valid while preventing routine
    /// encode work from outrunning either local Network.framework submission or
    /// the TCP sender buffer during a transient Wi-Fi slowdown.
    static var shouldPauseEncoding: Bool {
        shouldPauseEncoding(at: DispatchTime.now().uptimeNanoseconds)
    }

    static func shouldPauseEncoding(at nowNs: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state.wireless, state.ready else { return false }
        return state.sendsInFlight >= highWatermark ||
            state.largeSendOutstanding ||
            nowNs < state.pauseUntilNs
    }

    private static func telemetryLineLocked() -> String {
        let completionAverageMs = state.completionSamples > 0
            ? Double(state.completionTotalNs) / Double(state.completionSamples) / 1_000_000.0
            : 0.0
        let completionMaxMs = Double(state.completionMaxNs) / 1_000_000.0
        let headroomAverageKiB = state.headroomSamples > 0
            ? Double(state.headroomTotalBytes) / Double(state.headroomSamples) / 1024.0
            : 0.0
        let headroomMinKiB = Double(state.headroomMinBytes ?? 0) / 1024.0

        return String(
            format: "Wireless transport: sendComplete avg=%.2fms max=%.2fms, " +
                "TCP headroom avg=%.0fKiB min=%.0fKiB, capturePauses=%d forced=%d",
            completionAverageMs,
            completionMaxMs,
            headroomAverageKiB,
            headroomMinKiB,
            state.capturePauseDecisions,
            state.captureForcedDecisions
        )
    }

    private static func resetTelemetryCountersLocked() {
        state.completionSamples = 0
        state.completionTotalNs = 0
        state.completionMaxNs = 0
        state.headroomSamples = 0
        state.headroomTotalBytes = 0
        state.headroomMinBytes = nil
        state.capturePauseDecisions = 0
        state.captureForcedDecisions = 0
    }

    private static func resetTelemetryLocked() {
        state.oldestSendStartedNs = 0
        state.newestSendStartedNs = 0
        resetTelemetryCountersLocked()
    }

    // Test visibility without exposing mutable state to production callers.
    static func snapshotForTest() -> (
        generation: UInt64,
        wireless: Bool,
        ready: Bool,
        sendsInFlight: Int,
        pauseUntilNs: UInt64,
        availableSendBuffer: UInt32?,
        forcedCapturePending: Bool,
        largeSendOutstanding: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.generation,
            state.wireless,
            state.ready,
            state.sendsInFlight,
            state.pauseUntilNs,
            state.lastAvailableSendBuffer,
            state.forcedCapturePending,
            state.largeSendOutstanding
        )
    }

    static func telemetrySnapshotForTest() -> (
        completionSamples: Int,
        completionTotalNs: UInt64,
        completionMaxNs: UInt64,
        headroomSamples: Int,
        headroomTotalBytes: UInt64,
        headroomMinBytes: UInt32?,
        capturePauseDecisions: Int,
        captureForcedDecisions: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.completionSamples,
            state.completionTotalNs,
            state.completionMaxNs,
            state.headroomSamples,
            state.headroomTotalBytes,
            state.headroomMinBytes,
            state.capturePauseDecisions,
            state.captureForcedDecisions
        )
    }
}
