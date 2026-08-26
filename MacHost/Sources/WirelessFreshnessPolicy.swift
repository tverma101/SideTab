import Foundation

/// Experimental freshness budgets for the normal-Wi-Fi 60 FPS path.
///
/// Apple can use a proprietary low-latency link layer for Sidecar. SideScreen
/// runs over ordinary LAN/Wi-Fi, so it must bound stale history explicitly.
/// These values are experiment defaults, not claims that they are optimal on
/// every network. Runtime #21/#27 measurements decide the production values.
enum WirelessFreshnessPolicy {
    static let targetFrameRate = 60
    static let frameIntervalNs: UInt64 = 1_000_000_000 / UInt64(targetFrameRate)

    /// At most the frame currently draining plus one following frame may be
    /// reserved in the sender. This mirrors the useful part of Moonlight's
    /// balanced pacing model: one frame of jitter headroom, not an accumulating
    /// history queue.
    static let maxSenderInFlightFrames = 2

    /// Keep enough byte headroom for a large sync frame while the frame-count
    /// limit remains the primary freshness boundary. Oversized access units
    /// still need to be measured and handled by the encoder/transport audit.
    static let maxSenderInFlightBytes = 6 * 1024 * 1024
    static let estimatedFrameBytes = 256 * 1024

    /// Two 60-Hz intervals is a hard experimental stale-output budget. A frame
    /// older than this inside the decoder is no longer useful display history.
    /// First-frame/startup presentation remains exempt at the call site.
    static let maxDecodedFrameAgeNs = frameIntervalNs * 2

    /// A paced wireless receiver may hold no more than one extra decoded frame.
    /// The direct/immediate path remains zero-buffer and is the latency baseline.
    static let targetExtraPresentationFrames = 1

    static let senderLimits = FrameBackpressureLimits(
        maxInFlightFrames: maxSenderInFlightFrames,
        maxInFlightBytes: maxSenderInFlightBytes,
        estimatedFrameBytes: estimatedFrameBytes
    )

    static func shouldRender(decodedLatencyNs: UInt64, isFirstFrame: Bool) -> Bool {
        isFirstFrame || decodedLatencyNs <= maxDecodedFrameAgeNs
    }
}
