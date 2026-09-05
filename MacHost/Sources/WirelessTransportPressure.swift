import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples TCP send-buffer headroom; capture/VideoEncoder
/// consult the gate before doing routine work. Forced keyframes bypass it.
enum WirelessTransportPressure {
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

    static var forcedCapturePending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.wireless && state.ready && state.forcedCapturePending
    }

    /// Sample real TCP sender headroom before submitting an encoded frame.
    ///
    /// `availableSendBuffer` describes capacity *before* this frame is handed to
    /// Network.framework. Predict the residual headroom after the frame too; if
    /// this send would leave less than a small reserve, pause future pre-encode
    /// routine captures immediately instead of waiting for the next already-
    /// encoded frame to discover that the TCP queue is nearly full.
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
        let lowHeadroom = available < frame || residual < UInt64(minimumHeadroomBytes)

        if lowHeadroom {
            let deadline = nowNs &+ sendBufferPauseNs
            if deadline > state.pauseUntilNs {
                state.pauseUntilNs = deadline
            }
        } else {
            // Fresh evidence that this frame still leaves useful TCP headroom
            // should release an older buffer-pressure hold immediately. Local
            // sends-in-flight pressure is evaluated independently below.
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
