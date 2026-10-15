import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples the TCP send queue; VideoEncoder consults the
/// Wi-Fi gate before submitting routine captures. Forced keyframes bypass it.
///
/// Despite the historical name, this type also owns the per-connection send
/// accounting used by USBAdaptiveLoadController. USB does NOT use the binary
/// pause gate below: it converts those same signals into 120 -> 90 -> 60 pacing.
enum WirelessTransportPressure {
    private struct State {
        var generation: UInt64 = 0
        var wireless = false
        var ready = false
        var sendsInFlight = 0
        var bytesInFlight = 0
        var pauseUntilNs: UInt64 = 0
        var lastQueuedSendBytes: UInt32?
        var usbSendStartTimesNs: [UInt64] = []
    }

    private static let lock = NSLock()
    private static var state = State()

    /// Start a new video transport generation and return its pressure token.
    @discardableResult
    static func reset(wireless: Bool) -> UInt64 {
        lock.lock()
        state.generation &+= 1
        state.wireless = wireless
        state.ready = false
        state.sendsInFlight = 0
        state.bytesInFlight = 0
        state.pauseUntilNs = 0
        state.lastQueuedSendBytes = nil
        state.usbSendStartTimesNs.removeAll(keepingCapacity: true)
        let generation = state.generation
        lock.unlock()

        if wireless {
            USBAdaptiveLoadController.shared.retireCurrent()
        } else {
            USBAdaptiveLoadController.shared.reset(
                generation: generation,
                maxFPS: USBAdaptiveFramePacer.configuredMaxFPS(),
                startupGraceNs: USBAdaptiveLoadController.startupGraceNs
            )
        }
        return generation
    }

    static func setReady(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.ready = true
    }

    static func beginSend(
        generation: UInt64,
        bytes: Int = 0,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var usbCount: Int?
        lock.lock()
        if state.generation == generation, state.ready {
            state.sendsInFlight += 1
            state.bytesInFlight += max(0, bytes)
            if !state.wireless {
                state.usbSendStartTimesNs.append(nowNs)
                usbCount = state.sendsInFlight
            }
        }
        lock.unlock()

        if let usbCount {
            USBAdaptiveLoadController.shared.observeSendsInFlight(
                generation: generation,
                count: usbCount,
                nowNs: nowNs
            )
        }
    }

    static func completeSend(
        generation: UInt64,
        bytes: Int = 0,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var usbDurationNs: UInt64?
        var usbInFlightAfter = 0

        lock.lock()
        guard state.generation == generation else {
            lock.unlock()
            return
        }
        state.sendsInFlight = max(0, state.sendsInFlight - 1)
        state.bytesInFlight = max(0, state.bytesInFlight - max(0, bytes))
        if !state.wireless {
            if !state.usbSendStartTimesNs.isEmpty {
                let start = state.usbSendStartTimesNs.removeFirst()
                usbDurationNs = nowNs >= start ? nowNs - start : 0
            }
            usbInFlightAfter = state.sendsInFlight
        }
        lock.unlock()

        if let usbDurationNs {
            USBAdaptiveLoadController.shared.observeSendCompletion(
                generation: generation,
                durationNs: usbDurationNs,
                sendsInFlightAfter: usbInFlightAfter,
                nowNs: nowNs
            )
        }
    }

    /// Sample the TCP send queue before submitting an encoded frame.
    ///
    /// `queuedBytes` is `NWProtocolTCP.Metadata.availableSendBuffer`, which
    /// counts bytes still sitting in the kernel send buffer (see
    /// `WirelessFreshnessPolicy.maxQueuedBacklogBytes`). USB forwards the
    /// sample, unchanged, to the adaptive FPS controller instead of using this
    /// gate.
    ///
    /// On Wi-Fi, more than the policy limit queued beyond `frameBytes` (the
    /// frame just handed over, which is usually still queued) pauses *future
    /// pre-encode* routine captures for a short bounded window; a sample at or
    /// below it releases an older pause at once. An empty queue (0) is the
    /// healthiest reading there is. The deadline always expires by itself,
    /// so a probe frame eventually gets through and re-samples the socket.
    static func observeSendBuffer(
        generation: UInt64,
        queuedBytes: UInt32,
        frameBytes: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        guard state.generation == generation, state.ready else {
            lock.unlock()
            return
        }

        state.lastQueuedSendBytes = queuedBytes
        guard state.wireless else {
            lock.unlock()
            USBAdaptiveLoadController.shared.observeSendBuffer(
                generation: generation,
                queuedBytes: queuedBytes,
                frameBytes: frameBytes,
                nowNs: nowNs
            )
            return
        }
        defer { lock.unlock() }

        if Int(queuedBytes) - frameBytes > WirelessFreshnessPolicy.maxQueuedBacklogBytes {
            let deadline = nowNs &+ WirelessFreshnessPolicy.sendBufferPauseNs
            if deadline > state.pauseUntilNs {
                state.pauseUntilNs = deadline
            }
        } else {
            state.pauseUntilNs = 0
        }
    }

    static func retire(generation: UInt64) {
        lock.lock()
        guard state.generation == generation else {
            lock.unlock()
            return
        }
        let retireUSB = !state.wireless
        state.generation &+= 1
        state.ready = false
        state.sendsInFlight = 0
        state.bytesInFlight = 0
        state.pauseUntilNs = 0
        state.lastQueuedSendBytes = nil
        state.usbSendStartTimesNs.removeAll(keepingCapacity: true)
        state.wireless = false
        lock.unlock()

        if retireUSB {
            USBAdaptiveLoadController.shared.retire(generation: generation)
        }
    }

    /// Routine captures are suppressed only before VideoToolbox sees them on
    /// Wi-Fi. This keeps H.264/HEVC reference chains valid while preventing
    /// routine encode work from outrunning either local Network.framework
    /// submission or the TCP sender buffer during a transient Wi-Fi slowdown.
    /// USB pressure is handled by USBAdaptiveLoadController instead.
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
        queuedSendBytes: UInt32?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.sendsInFlight,
            state.bytesInFlight,
            state.pauseUntilNs,
            state.lastQueuedSendBytes
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
        queuedSendBytes: UInt32?
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
            state.lastQueuedSendBytes
        )
    }
}
