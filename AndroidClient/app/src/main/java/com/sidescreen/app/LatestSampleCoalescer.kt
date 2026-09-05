package com.sidescreen.app

/**
 * One-slot lossy queue for high-rate motion samples.
 *
 * DOWN/UP/CANCEL never use this class. Only replaceable MOVE/HOVER samples do:
 * while the single network writer is busy, producers overwrite `pending` with
 * the newest position instead of building an arbitrarily long coroutine queue.
 *
 * Epochs preserve boundary ordering. A queued drain from gesture/contact N can
 * never consume a MOVE/HOVER that arrived after the UP/DOWN barrier for N+1.
 */
internal class LatestSampleCoalescer<T> {
    private data class Pending<T>(
        val epoch: Long,
        val value: T,
    )

    private val lock = Any()
    private var epoch = 0L
    private var pending: Pending<T>? = null
    private var scheduledEpoch: Long? = null

    /**
     * Store the newest sample in the current epoch. Returns the epoch token
     * when the caller must schedule a drain, or null when one already exists.
     */
    fun offer(value: T): Long? =
        synchronized(lock) {
            pending = Pending(epoch, value)
            if (scheduledEpoch == epoch) {
                null
            } else {
                scheduledEpoch = epoch
                epoch
            }
        }

    /** Take the newest sample only if it belongs to this drain's epoch. */
    fun takeLatest(drainEpoch: Long): T? =
        synchronized(lock) {
            if (scheduledEpoch != drainEpoch) return@synchronized null
            val current = pending
            if (current?.epoch != drainEpoch) return@synchronized null
            pending = null
            current.value
        }

    /**
     * Called after a bounded drain burst. True means this exact epoch still has
     * pending motion and needs a continuation. A newer boundary/epoch makes an
     * old drain immediately inert.
     */
    fun finishBurst(drainEpoch: Long): Boolean =
        synchronized(lock) {
            if (scheduledEpoch != drainEpoch) return@synchronized false
            if (pending?.epoch == drainEpoch) {
                true
            } else {
                scheduledEpoch = null
                false
            }
        }

    /**
     * Drop obsolete pending motion and start a new ordering epoch. Existing
     * drain tasks retain their old token and therefore cannot consume future
     * motion. The boundary packet itself is queued separately by StreamClient.
     */
    fun advanceBoundary(): Long =
        synchronized(lock) {
            pending = null
            epoch += 1
            epoch
        }

    internal fun snapshotForTest(): Triple<Long, Long?, T?> =
        synchronized(lock) {
            Triple(epoch, scheduledEpoch, pending?.value)
        }
}
