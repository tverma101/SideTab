package com.sidescreen.app

/**
 * Receiver half of the wireless freshness contract. The decoder may keep one
 * presentation interval of scheduling slack, but it must not put visibly old
 * desktop frames on the panel.
 */
object WirelessFreshnessPolicy {
    const val TARGET_FRAME_RATE = 60
    const val FRAME_INTERVAL_NS = 1_000_000_000L / TARGET_FRAME_RATE
    const val MAX_DECODED_FRAME_AGE_NS = FRAME_INTERVAL_NS * 2

    fun shouldRender(decodedLatencyNs: Long, isFirstFrame: Boolean): Boolean {
        return isFirstFrame || decodedLatencyNs <= MAX_DECODED_FRAME_AGE_NS
    }

    /**
     * Whether a decoded output buffer belongs on the panel, given the transport
     * and whether its latency is even interpretable.
     *
     * This exists because the caller used to fold the freshness policy into a
     * `!hasValidLatency` escape hatch: any output older than
     * [maxReasonableLatencyNs] short-circuited straight to "render", so the two
     * frames *most* overdue — about sixty times the wireless budget — were the
     * only ones guaranteed to bypass the policy. `WirelessFreshnessPolicy`'s own
     * tests could not see it, because the policy was never called.
     *
     * Over budget now always means drop, on every transport. USB keeps a looser
     * ceiling because its larger frames and slower pipeline make a higher age
     * budget intentional, not an oversight.
     *
     * @param maxReasonableLatencyNs the decoder's own ceiling beyond which a
     *   presentation timestamp is not comparable to the current clock.
     * @param maxRenderLatencyNs the looser ceiling applied to USB sessions.
     */
    fun shouldRenderOutput(
        decodedLatencyNs: Long,
        hasValidLatency: Boolean,
        isFirstOutput: Boolean,
        wireless: Boolean,
        maxReasonableLatencyNs: Long,
        maxRenderLatencyNs: Long,
    ): Boolean {
        if (isFirstOutput) return true
        if (wireless) {
            // An uninterpretable latency is not permission to draw a stale
            // frame. Treat it as arbitrarily old so it is dropped.
            val effective = if (hasValidLatency) decodedLatencyNs else Long.MAX_VALUE
            return shouldRender(effective, isFirstFrame = false)
        }
        return !hasValidLatency || decodedLatencyNs <= maxRenderLatencyNs
    }
}
