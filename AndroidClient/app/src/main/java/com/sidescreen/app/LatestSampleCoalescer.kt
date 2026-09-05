package com.sidescreen.app

/**
 * One-slot lossy queue for high-rate motion samples.
 *
 * DOWN/UP/CANCEL never use this class. Only replaceable MOVE/HOVER samples do:
 * while the single network writer is busy, producers overwrite `pending` with
 * the newest position instead of building an arbitrarily long coroutine queue.
 */
internal class LatestSampleCoalescer<T> {
    private val lock = Any()
    private var pending: T? = null
    private var drainScheduled = false

    /** Store the latest sample. True means the caller must schedule a drain. */
    fun offer(value: T): Boolean =
        synchronized(lock) {
            pending = value
            if (drainScheduled) {
                false
            } else {
                drainScheduled = true
                true
            }
        }

    /** Take the newest currently pending sample, if any. */
    fun takeLatest(): T? =
        synchronized(lock) {
            val value = pending
            pending = null
            value
        }

    /**
     * Called after a bounded drain burst. Returns true when another drain must
     * be queued; otherwise releases the scheduled latch for the next producer.
     */
    fun finishBurst(): Boolean =
        synchronized(lock) {
            if (pending != null) {
                true
            } else {
                drainScheduled = false
                false
            }
        }

    /** Drop motion that is obsolete because a boundary event carries final state. */
    fun clearPending() {
        synchronized(lock) {
            pending = null
        }
    }

    internal fun snapshotForTest(): Pair<Boolean, T?> =
        synchronized(lock) { drainScheduled to pending }
}
