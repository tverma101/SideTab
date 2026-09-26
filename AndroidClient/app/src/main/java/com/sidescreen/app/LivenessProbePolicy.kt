package com.sidescreen.app

/** Pure timeout policy shared by the video and out-of-band liveness probes. */
internal object LivenessProbePolicy {
    fun isExpired(
        sentAtNs: Long,
        nowNs: Long,
        timeoutNs: Long,
        paused: Boolean,
    ): Boolean =
        !paused && sentAtNs > 0L && nowNs >= sentAtNs && nowNs - sentAtNs > timeoutNs
}
