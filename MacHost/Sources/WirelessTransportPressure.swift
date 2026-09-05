import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples TCP send-buffer headroom; capture/VideoEncoder
/// consult the gate before doing routine work. Forced keyframes bypass it.
enum WirelessTransportPressure {
    enum CaptureAdmission {
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
    }

    private static let lock = NSLock()
    private static var state = State()
    private static let highWatermark = 2
    private static let minimumHeadroomBytes = 32 * 1024
    private static let sendBufferPauseNs: UInt64 = 20_000_000

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
        return state.generation
    }

    static func setReady(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.ready = true
    }

    static func beginSend(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation, state.ready else { return }
        state.sendsInFlight += 1
    }

    static func completeSend(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.sendsInFlight = max(0, state.sendsInFlight - 1)
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
        if state.forcedCapturePending { return .forced }
        if state.sendsInFlight >= highWatermark || nowNs < state.pauseUntilNs {
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
    /// The pause is short and bounded, so a probe frame always gets another
    /// chance to sample current socket headroom. Forced recovery keyframes still
    /// bypass this gate in VideoEncoder.
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
        let available = UInt64(availableBytes)
        let frame = UInt64(max(1, frameBytes))
        let residual = available > frame ? available - frame : 0
        let reserve = max(UInt64(minimumHeadroomBytes), frame)
        let lowHeadroom = available < frame || residual < reserve

        if lowHeadroom {
            let deadline = nowNs &+ sendBufferPauseNs
            if deadline > state.pauseUntilNs {
                state.pauseUntilNs = deadline
            }
        } else {
            // Fresh evidence that this frame still leaves room for another
            // similarly-sized frame should release an older buffer-pressure hold
            // immediately. Local sends-in-flight pressure remains independent.
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
        state.wireless = false
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
        return state.sendsInFlight >= highWatermark || nowNs < state.pauseUntilNs
    }

    // Test visibility without exposing mutable state to production callers.
    static func snapshotForTest() -> (
        generation: UInt64,
        wireless: Bool,
        ready: Bool,
        sendsInFlight: Int,
        pauseUntilNs: UInt64,
        availableSendBuffer: UInt32?,
        forcedCapturePending: Bool
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
            state.forcedCapturePending
        )
    }
}
