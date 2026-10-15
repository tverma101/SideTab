import Foundation

/// The bounded freshness contract shared by the host's wireless sender and the
/// Android receiver. USB keeps its existing user-selected limits.
enum WirelessFreshnessPolicy {
    static let targetFrameRate = 60
    static let frameIntervalNs: UInt64 = 1_000_000_000 / UInt64(targetFrameRate)

    /// Two 60 Hz intervals gives the receiver one presentation frame of
    /// scheduling slack without allowing a visibly stale desktop to queue.
    static let maxDecodedFrameAgeNs = frameIntervalNs * 2

    /// Routine encodes do not outrun the TCP/decoder pipeline by more than two
    /// encoded frames or approximately one frame-sized burst. Forced sync
    /// frames may bypass this budget during startup or recovery.
    static let maxSenderInFlightFrames = 2
    static let maxSenderInFlightBytes = 6 * 1024 * 1024

    /// Wireless rate control is deliberately bounded independently of the USB
    /// bitrate setting, whose historical default is much higher.
    static let averageBitrateMbps = 40
    static let peakBitrateMbps = 60

    /// `NWProtocolTCP.Metadata.availableSendBuffer` is the number of bytes
    /// still queued in the kernel send buffer, not free space: it reads 0 on
    /// an idle socket and climbs to the 128 KiB buffer size against a stalled
    /// peer (measured 2026-10-06). It is sampled just before a frame is sent,
    /// so it holds earlier frames the peer has not taken yet. The frame about
    /// to be sent stands in for one frame still draining: live 60 fps Wi-Fi
    /// motion sat at p50 16 KiB / p90 40 KiB queued with ~20 KiB frames, while
    /// a healthy 110 KiB frame alone fills most of the buffer. More than
    /// 64 KiB beyond that means the link has fallen behind, and routine
    /// encodes pause briefly.
    static let maxQueuedBacklogBytes = 64 * 1024
    static let sendBufferPauseNs: UInt64 = 20_000_000

    static func shouldRender(decodedLatencyNs: UInt64, isFirstFrame: Bool) -> Bool {
        isFirstFrame || decodedLatencyNs <= maxDecodedFrameAgeNs
    }
}
