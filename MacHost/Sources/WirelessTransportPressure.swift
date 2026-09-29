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
        var bytesInFlight = 0
        var pauseUntilNs: UInt64 = 0
        var lastAvailableSendBuffer: UInt32?
    }

    private static let lock = NSLock()
    private static var state = State()

    /// Start a new video transport generation and return its pressure token.
    @discardableResult
    static func reset(wireless: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.wireless = wireless
        state.ready = false
        state.sendsInFlight = 0
        state.bytesInFlight = 0
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

    static func beginSend(generation: UInt64, bytes: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation, state.ready else { return }
        state.sendsInFlight += 1
        state.bytesInFlight += max(0, bytes)
    }

    static func completeSend(generation: UInt64, bytes: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.sendsInFlight = max(0, state.sendsInFlight - 1)
        state.bytesInFlight = max(0, state.bytesInFlight - max(0, bytes))
    }

    /// Sample real TCP sender headroom before submitting an encoded frame.
    ///
    /// If the socket has less than a small amount of headroom, pause *future
    /// pre-encode* routine captures for a short bounded window. Do not require
    /// the kernel to have room for the entire encoded frame: a normal HEVC
    /// frame can be larger than the currently available TCP window even when
    /// the connection is healthy, and Network.framework will stream that frame
    /// while the bounded in-flight budget prevents an unbounded queue. Using
    /// the whole frame as the threshold self-throttles a healthy 60-Hz stream
    /// to roughly every other frame on small Wi-Fi send buffers.
    ///
    /// The deadline always expires by itself, guaranteeing that a probe frame
    /// eventually gets through and re-samples the socket.
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
        // `frameBytes` is intentionally not part of this threshold. It is a
        // useful diagnostic input at call sites, but requiring one complete
        // frame of kernel headroom made the sender skip every next frame when
        // the frame was larger than the socket's advertised free window.
        _ = frameBytes
        let required = UInt64(WirelessFreshnessPolicy.minimumSendBufferHeadroomBytes)
        // Network.framework reports zero for this metadata on some healthy
        // Wi-Fi paths (including the IPv6 route used by the live tablet). Zero
        // is therefore not a reliable low-water mark here. The explicit
        // in-flight frame/byte budgets remain the hard safety boundary when
        // the kernel does not provide a usable headroom sample.
        if availableBytes > 0 && UInt64(availableBytes) < required {
            let deadline = nowNs &+ WirelessFreshnessPolicy.sendBufferPauseNs
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
        state.bytesInFlight = 0
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
        return state.sendsInFlight >= WirelessFreshnessPolicy.maxSenderInFlightFrames ||
            state.bytesInFlight >= WirelessFreshnessPolicy.maxSenderInFlightBytes ||
            nowNs < state.pauseUntilNs
    }

    /// Lightweight live diagnostics for separating socket pressure from
    /// encoder/capture pressure. The values are sampled under the same lock as
    /// the admission decision, so the log cannot describe a different
    /// transport generation.
    static func diagnosticSnapshot() -> (
        sendsInFlight: Int,
        bytesInFlight: Int,
        pauseUntilNs: UInt64,
        availableSendBuffer: UInt32?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.sendsInFlight,
            state.bytesInFlight,
            state.pauseUntilNs,
            state.lastAvailableSendBuffer
        )
    }

    // Test visibility without exposing mutable state to production callers.
    static func snapshotForTest() -> (
        generation: UInt64,
        wireless: Bool,
        ready: Bool,
        sendsInFlight: Int,
        bytesInFlight: Int,
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
            state.bytesInFlight,
            state.pauseUntilNs,
            state.lastAvailableSendBuffer
        )
    }
}
