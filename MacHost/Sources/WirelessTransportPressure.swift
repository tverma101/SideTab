import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records shallow local
/// send pressure and samples TCP send-buffer headroom; VideoEncoder consults
/// the Wi-Fi gate before submitting routine captures. Forced keyframes bypass it.
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
        var pauseUntilNs: UInt64 = 0
        var lastAvailableSendBuffer: UInt32?
        var usbSendStartTimesNs: [UInt64] = []
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
        state.generation &+= 1
        state.wireless = wireless
        state.ready = false
        state.sendsInFlight = 0
        state.pauseUntilNs = 0
        state.lastAvailableSendBuffer = nil
        state.usbSendStartTimesNs.removeAll(keepingCapacity: true)
        let generation = state.generation
        lock.unlock()

        if wireless {
            USBAdaptiveLoadController.shared.retireCurrent()
        } else {
            USBAdaptiveLoadController.shared.reset(
                generation: generation,
                maxFPS: USBAdaptiveFramePacer.configuredMaxFPS()
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
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var usbCount: Int?
        lock.lock()
        if state.generation == generation, state.ready {
            state.sendsInFlight += 1
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

    /// Sample real TCP sender headroom before submitting an encoded frame.
    ///
    /// Wi-Fi keeps the existing short binary pause behavior. USB forwards the
    /// same real sender-headroom sample to the adaptive FPS controller instead.
    static func observeSendBuffer(
        generation: UInt64,
        availableBytes: UInt32,
        frameBytes: Int,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        var isUSB = false

        lock.lock()
        guard state.generation == generation, state.ready else {
            lock.unlock()
            return
        }

        state.lastAvailableSendBuffer = availableBytes
        if !state.wireless {
            isUSB = true
            lock.unlock()
        } else {
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
            lock.unlock()
        }

        if isUSB {
            USBAdaptiveLoadController.shared.observeSendBuffer(
                generation: generation,
                availableBytes: availableBytes,
                frameBytes: frameBytes,
                nowNs: nowNs
            )
        }
    }

    static func retire(generation: UInt64) {
        var retireUSB = false
        lock.lock()
        guard state.generation == generation else {
            lock.unlock()
            return
        }
        retireUSB = !state.wireless
        state.generation &+= 1
        state.ready = false
        state.sendsInFlight = 0
        state.pauseUntilNs = 0
        state.lastAvailableSendBuffer = nil
        state.usbSendStartTimesNs.removeAll(keepingCapacity: true)
        state.wireless = false
        lock.unlock()

        if retireUSB {
            USBAdaptiveLoadController.shared.retire(generation: generation)
        }
    }

    /// Routine captures are suppressed only before VideoToolbox sees them on
    /// Wi-Fi. USB pressure is handled by USBAdaptiveLoadController instead.
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
