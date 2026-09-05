package com.sidescreen.app

/**
 * Generation fence for asynchronous recovery work.
 *
 * Android NSD callbacks can arrive after the user forgets a host, scans a new
 * QR, or starts a newer reconnect action. A token returned by [begin] is valid
 * only until the next [begin] or [invalidate], so stale callbacks cannot mutate
 * pairing state or start a connection after newer user intent wins.
 */
internal class RecoveryAttemptFence {
    private var generation = 0L

    @Synchronized
    fun begin(): Long {
        generation += 1
        return generation
    }

    @Synchronized
    fun invalidate() {
        generation += 1
    }

    @Synchronized
    fun isCurrent(token: Long): Boolean = token == generation
}
