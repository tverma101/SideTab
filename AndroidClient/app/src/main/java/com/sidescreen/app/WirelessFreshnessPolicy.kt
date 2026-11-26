package com.sidescreen.app

/**
 * Pure freshness policy for SideScreen's ordinary-Wi-Fi 60 FPS path.
 *
 * The immediate receiver remains the zero-buffer latency baseline. The
 * optional paced experiment may hold at most one extra decoded frame to absorb
 * Wi-Fi/vsync jitter; it must never become an unbounded smoothness queue.
 */
internal object WirelessFreshnessPolicy {
    const val TARGET_FPS = 60
    const val FRAME_INTERVAL_NS = 1_000_000_000L / TARGET_FPS

    /** Two 60-Hz intervals: beyond this, decoder output is stale history. */
    const val MAX_DECODED_FRAME_AGE_NS = FRAME_INTERVAL_NS * 2

    /** One extra decoded frame is the maximum pacing headroom under test. */
    const val TARGET_EXTRA_PRESENTATION_FRAMES = 1

    fun shouldRender(
        decodedLatencyNs: Long,
        isFirstFrame: Boolean,
    ): Boolean =
        isFirstFrame || decodedLatencyNs <= MAX_DECODED_FRAME_AGE_NS
}
