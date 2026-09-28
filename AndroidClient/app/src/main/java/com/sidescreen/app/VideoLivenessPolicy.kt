package com.sidescreen.app

/**
 * Pure retirement policy for the in-band video liveness probe.
 *
 * The client used to retire a working transport on a 6-second read-loop timer
 * whose entire evidence base was "did the read loop produce anything". That is
 * not liveness:
 *
 *  - The Mac deliberately sends no frames for an unchanged desktop
 *    (ScreenCaptureKit clean-frame suppression), so silence is the normal state
 *    of a healthy, idle stream.
 *  - The read loop is not isolated from the decoder: it calls `onFrameReceived`
 *    inline, which reaches `MediaCodec.getInputBuffer`/`queueInputBuffer`. Under
 *    decoder backpressure, GC or thermal throttling it can stall for seconds.
 *  - A pong is queued behind video data on the host, so an actively delivering
 *    stream can miss its own probe deadline.
 *
 * Retiring on that evidence is what made the tablet drop its display at random
 * while the Mac kept streaming. A transport is now only retired on corroborated
 * evidence: a long silence, a dead read path, and a blocked write or a socket
 * error to back it up.
 */
internal object VideoLivenessPolicy {
    /**
     * Per-probe budget. Three times the probe interval so a single lost probe on
     * a congested link is never sufficient, and far above any plausible read-loop
     * stall. Two consecutive misses are required before anything is closed, so
     * worst-case detection is roughly `TIMEOUT * MAX_UNANSWERED` and stays well
     * inside the host's five-minute session deadline.
     */
    const val PROBE_TIMEOUT_NS = 20_000_000_000L

    /**
     * Independent unanswered probes required before the transport is retired.
     * One is not evidence: it is equally consistent with a queued pong, a clean
     * frame gap, or a decoder stall.
     */
    const val MAX_UNANSWERED_PROBES = 2

    /**
     * A probe write that blocks this long means the send buffer is wedged. That
     * is a genuine transport fault rather than an application-layer ambiguity,
     * so it is reported on its own instead of being folded into the silence
     * counter.
     */
    const val WRITE_BLOCKED_NS = 10_000_000_000L

    /**
     * Whether the read path is delivering. The watchdog may not retire a
     * transport that is actively receiving: a read-loop stall and a dead socket
     * look identical from the probe's side, and only the read path itself can
     * tell them apart.
     */
    fun isReadPathAlive(lastReadNs: Long, nowNs: Long, staleAfterNs: Long): Boolean {
        if (lastReadNs <= 0L || nowNs < lastReadNs) return false
        return nowNs - lastReadNs < staleAfterNs
    }

    /**
     * Whether an unanswered probe run is enough to retire the transport.
     * Requires an expired probe budget, a read path that has itself gone quiet,
     * and [MAX_UNANSWERED_PROBES] consecutive misses. An expired clock on its
     * own is never sufficient.
     */
    fun shouldRetireTransport(
        unansweredProbes: Int,
        readPathAlive: Boolean,
        nowNs: Long,
        firstProbeNs: Long,
        timeoutNs: Long = PROBE_TIMEOUT_NS,
        maxUnanswered: Int = MAX_UNANSWERED_PROBES,
    ): Boolean {
        // An actively delivering read path outranks every timer here.
        if (readPathAlive) return false
        if (firstProbeNs <= 0L || nowNs < firstProbeNs) return false
        if (unansweredProbes < maxUnanswered) return false
        return nowNs - firstProbeNs > timeoutNs
    }

    /**
     * A probe write that blocked past [WRITE_BLOCKED_NS] is transport evidence
     * on its own, independent of how many pongs came back.
     */
    fun isWriteBlocked(writeDurationNs: Long): Boolean =
        writeDurationNs > WRITE_BLOCKED_NS
}
