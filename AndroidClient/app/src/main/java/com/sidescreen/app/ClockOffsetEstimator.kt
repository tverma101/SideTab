package com.sidescreen.app

/**
 * Estimates the offset between the Mac's uptime clock (DispatchTime's
 * uptimeNanoseconds, what the host puts in the frame header and the control
 * pong) and this device's CLOCK_MONOTONIC (System.nanoTime()).
 *
 * The two clocks are unrelated in origin, so a host timestamp can only be used
 * against the local clock through this offset. The control-channel pong carries
 * the host's clock read at send time, which brackets the true offset between
 * [hostSendNs] - [arrivalNs] and [hostSendNs] - [clientSentNs]; the sample with
 * the lowest round trip has the tightest bracket, so it is the one kept.
 *
 * Only the best sample is retained, and consumers must still treat a result as
 * an estimate: it drifts with host wake/sleep and with a peer whose monotonic
 * base is reset, so a derived latency is clamped rather than trusted.
 */
internal class ClockOffsetEstimator {
    private val lock = Any()
    private var bestRttNs = Long.MAX_VALUE
    private var bestOffsetNs = 0L
    private var hasSample = false

    /**
     * Record one pong. Returns the current best offset (host clock minus local
     * clock), or null until a usable sample has arrived. A reply whose
     * timestamps do not order correctly (clock stepped, corrupt read) is
     * ignored rather than allowed to poison the estimate.
     */
    fun offer(
        clientSentNs: Long,
        hostSendNs: Long,
        arrivalNs: Long,
    ): Long? =
        synchronized(lock) {
            val rttNs = arrivalNs - clientSentNs
            if (rttNs < 0 || hostSendNs < 0) return@synchronized currentOffsetLocked()
            if (!hasSample || rttNs < bestRttNs) {
                bestRttNs = rttNs
                bestOffsetNs = hostSendNs - (clientSentNs + rttNs / 2)
                hasSample = true
            }
            bestOffsetNs
        }

    /** Best known offset, or null when no pong has been answered yet. */
    val offsetNs: Long?
        get() = synchronized(lock) { currentOffsetLocked() }

    /** Round trip of the sample the offset came from, in nanoseconds. */
    val sampleRttNs: Long
        get() = synchronized(lock) { if (hasSample) bestRttNs else -1L }

    /** Round trip of the sample the offset came from, in milliseconds. */
    val sampleRttMs: Double
        get() = sampleRttNs.let { if (it < 0L) -1.0 else it / 1e6 }

    private fun currentOffsetLocked(): Long? = if (hasSample) bestOffsetNs else null

    /**
     * Age of a host-domain event, measured on the local clock. Returns null when
     * no offset is known, and never a negative age: an estimate that lands in
     * the future means the offset is stale, not that time travelled backwards.
     */
    fun hostEventAgeNs(
        hostEventNs: Long,
        localNowNs: Long,
    ): Long? {
        val offset = offsetNs ?: return null
        val localEquivalent = hostEventNs - offset
        val age = localNowNs - localEquivalent
        return if (age < 0L) null else age
    }
}
