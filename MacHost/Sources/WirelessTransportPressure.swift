import Foundation

/// Crosses the Network.framework -> VideoToolbox boundary without dropping
/// already-encoded reference frames. StreamingServer records outstanding
/// wireless sends; VideoEncoder consults the gate before submitting routine
/// captures to VideoToolbox. Forced keyframes deliberately bypass the gate.
enum WirelessTransportPressure {
    private struct State {
        var generation: UInt64 = 0
        var wireless = false
        var ready = false
        var sendsInFlight = 0
    }

    private static let lock = NSLock()
    private static var state = State()
    private static let highWatermark = 2

    /// Start a new video transport generation and return its pressure token.
    @discardableResult
    static func reset(wireless: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.wireless = wireless
        state.ready = false
        state.sendsInFlight = 0
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

    static func retire(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return }
        state.generation &+= 1
        state.ready = false
        state.sendsInFlight = 0
        state.wireless = false
    }

    /// Routine captures should not be submitted while Network.framework still
    /// owns two prior wireless frames. Skipping here is codec-safe because
    /// VideoToolbox never sees the omitted capture, so its reference chain is
    /// built only from frames that will actually be transmitted.
    static var shouldPauseEncoding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.wireless && state.ready && state.sendsInFlight >= highWatermark
    }

    // Test visibility without exposing mutable state to production callers.
    static func snapshotForTest() -> (generation: UInt64, wireless: Bool, ready: Bool, sendsInFlight: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (state.generation, state.wireless, state.ready, state.sendsInFlight)
    }
}
