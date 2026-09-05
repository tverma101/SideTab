import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples TCP send-buffer headroom; VideoEncoder consults
/// the gate before submitting routine captures. Forced keyframes bypass it.
enum WirelessTransportPressure {
    private struct State {
        var generation: UInt64 = 0
        var wireless = false
        var ready = false
        var sendsInFlight = 0
        var pauseUntilNs: UInt64 = 0
        var lastAvailableSendBuffer: UInt32?
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

    /// Sample real TCP sender headroom before submitting an encoded frame.
    ///
    /// If the socket cannot currently hold at least one frame (or a small 32 KiB
    /// floor for tiny frames), pause *future pre-encode* routine captures for a
    /// short bounded window. The deadline always expires by itself, guaranteeing
    /// that a probe frame eventually gets through and re-samples the socket.
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
        let required = UInt64(max(minimumHeadroomBytes, max(1, frameBytes)))
        if UInt64(availableBytes) < required {
            let deadline = nowNs &+ sendBufferPauseNs
            if deadline > state.pauseUntilNs {
                state.pauseUntilNs = deadline
            }
        } else {
            // Fresh evidence that the TCP queue has room should release an older
            // buffer-pressure hold immediately. Local sends-in-flight pressure is
            // still evaluated independently below.
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
        availableSendBuffer: UInt32?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.generation,
            state.wireless,
            state.ready,
            state.sendsInFlight,
            state.pauseUntilNs,
            state.lastAvailableSendBuffer
        )
    }
}
