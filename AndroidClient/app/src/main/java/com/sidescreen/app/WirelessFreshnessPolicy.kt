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
}
