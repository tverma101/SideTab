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
 * Keeping only the tightest sample is not enough on its own. The host clock is
 * `mach_absolute_time`, which stops advancing while the Mac is asleep, so after
 * a host sleep the true offset moves and the latched sample is simply wrong. It
 * is also nearly unbeatable once latched: an early 200 microsecond sample on an
 * idle network can never be improved on, so the estimate would stay wrong for
 * the rest of the session. Two rules keep it honest:
 *
 *  - A new sample whose bracket does not contain the current estimate *proves*
 *    the offset moved, so it is adopted immediately regardless of its RTT.
 *  - The latched sample expires after [maxSampleAgeNs] so a drift that keeps the
 *    brackets overlapping (a slow relative slip) is still eventually re-based.
 *
 * Only the best sample is retained, and consumers must still treat a result as
 * an estimate: it drifts with host wake/sleep and with a peer whose monotonic
 * base is reset, so a derived latency is clamped rather than trusted.
 */
internal class ClockOffsetEstimator {
    private val lock = Any()
    private var bestRttNs = Long.MAX_VALUE
    private var bestOffsetNs = 0L
    private var bestSampleAtLocalNs = 0L
    private var hasSample = false

    /**
     * How long a latched sample stays authoritative. Long enough that ordinary
     * jitter never re-bases mid-session, short enough that a host sleep or a
     * slow relative slip is corrected well within a stream's lifetime.
     */
    var maxSampleAgeNs: Long = 60_000_000_000L

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
            // The true offset lies within this half-open bracket: the host read
            // its clock no earlier than we sent, and no later than it arrived.
            val lowerBound = hostSendNs - arrivalNs
            val upperBound = hostSendNs - clientSentNs
            val offsetNs = hostSendNs - (clientSentNs + rttNs / 2)

            if (!hasSample) {
                adoptLocked(rttNs, offsetNs, arrivalNs)
                return@synchronized bestOffsetNs
            }

            // Proof of drift: if the latched estimate is not inside this
            // sample's bracket, no round trip can reconcile them, so the host
            // clock has moved relative to ours. Take the new reading now.
            if (bestOffsetNs < lowerBound || bestOffsetNs > upperBound) {
                adoptLocked(rttNs, offsetNs, arrivalNs)
                return@synchronized bestOffsetNs
            }

            val sampleAgeNs = arrivalNs - bestSampleAtLocalNs
            if (sampleAgeNs >= 0 && sampleAgeNs > maxSampleAgeNs) {
                // Expired. A slower reading beats a stale precise one, because
                // a wrong offset makes every derived latency wrong too.
                adoptLocked(rttNs, offsetNs, arrivalNs)
                return@synchronized bestOffsetNs
            }

            if (rttNs < bestRttNs) {
                adoptLocked(rttNs, offsetNs, arrivalNs)
            }
            bestOffsetNs
        }

    private fun adoptLocked(
        rttNs: Long,
        offsetNs: Long,
        localNowNs: Long,
    ) {
        bestRttNs = rttNs
        bestOffsetNs = offsetNs
        bestSampleAtLocalNs = localNowNs
        hasSample = true
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
