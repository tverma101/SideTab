package com.sidescreen.app

import java.net.Socket
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Detects a socket write that has been blocked longer than its budget and hands
 * the exact captured socket to an owner-supplied recovery action.
 *
 * A Java socket write is not interruptible. When the send buffer fills and the
 * peer stops reading, `OutputStream.write` parks the calling thread until the
 * socket closes — and because every writer in this app is serialized behind
 * that thread (the single `TouchThread` executor for video, `sendLock` for
 * control), one wedged write stalls every later packet too: touch, stylus,
 * keyframe requests, and the video liveness probe. A post-write duration check
 * can never observe that case, because the write never returns.
 *
 * So the deadline has to live somewhere the blocked writer cannot hold. This
 * watchdog runs on a shared single-thread scheduler and keeps its own small
 * lock separate from the caller's writer locks:
 *
 * - [arm] records the socket plus an opaque token and a deadline. It allocates
 *   nothing and never schedules per packet. One low-rate repeating poll is
 *   created lazily on the first armed write, kept alive across short idle gaps
 *   so 120 Hz traffic does not churn the scheduler, and cancelled only at
 *   shutdown or after a long idle cooldown.
 * - [disarm] clears the deadline after the write returns. A stale deadline can
 *   never close a socket that was re-armed for newer work: arming overwrites
 *   both the captured socket and the token. [arm] returns that token; callers
 *   must pass it back to [disarm].
 * - The recovery callback runs on the scheduler thread while this watchdog's own
 *   lock is held, so a write that completes and re-arms the same socket cannot
 *   interleave between the deadline check and the recovery action. The callback
 *   receives the exact socket and arm token captured at [arm] time, and must not
 *   block on a writer lock or the watchdog thread becomes the next casualty.
 *
 * The callback returns true to keep watching the same socket (used when an
 * inbound read path proves the transport is still healthy), false once the
 * owner has acted or the socket is no longer current.
 */
internal class SocketWriteWatchdog(
    private val budgetMs: Long,
    private val pollIntervalMs: Long = DEFAULT_POLL_INTERVAL_MS,
    private val onBlockedWrite: (socket: Socket, token: Long) -> Boolean,
) {
    private val lock = Any()

    @Volatile
    private var armedSocket: Socket? = null

    @Volatile
    private var armedToken = 0L

    /** Absolute deadline for the armed write; 0 when nothing is armed. */
    @Volatile
    private var deadlineNs = 0L

    private var ticker: ScheduledFuture<*>? = null
    private var closed = false
    private var idlePolls = 0

    /** Start (or refresh) the deadline for a write about to block on [socket]. */
    fun arm(socket: Socket): Long {
        synchronized(lock) {
            if (closed) return 0L
            val token = ++armedToken
            armedSocket = socket
            deadlineNs = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budgetMs)
            idlePolls = 0
            if (ticker == null) {
                ticker = SCHEDULER.scheduleWithFixedDelay(
                    Runnable { poll() },
                    pollIntervalMs,
                    pollIntervalMs,
                    TimeUnit.MILLISECONDS,
                )
            }
            return token
        }
    }

    /** Clear the deadline after [token]'s write returned. */
    fun disarm(token: Long) {
        synchronized(lock) {
            if (closed || armedToken != token || deadlineNs == 0L) return
            deadlineNs = 0L
            armedSocket = null
        }
    }

    /** Stop watching. Idempotent; used when the owning channel is torn down. */
    fun shutdown() {
        synchronized(lock) {
            if (closed) return
            closed = true
            deadlineNs = 0L
            armedSocket = null
            stopTicker()
        }
    }

    private fun poll() {
        synchronized(lock) {
            if (closed) {
                stopTicker()
                return
            }
            val socket = armedSocket
            if (socket == null || deadlineNs == 0L) {
                idlePolls += 1
                if (idlePolls >= IDLE_POLLS_BEFORE_STOP) {
                    stopTicker()
                }
                return
            }
            idlePolls = 0
            if (System.nanoTime() < deadlineNs) return

            val token = armedToken
            val keepWatching =
                try {
                    onBlockedWrite(socket, token)
                } catch (_: Throwable) {
                    false
                }
            if (closed || armedSocket !== socket || armedToken != token) return
            if (keepWatching) {
                // Re-arm only if this exact write is still the armed one. A
                // completed write that disarmed while the callback ran must not
                // resurrect a deadline for a socket nobody is writing to.
                deadlineNs = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budgetMs)
            } else {
                // The owner has recovered, or the socket stopped being current.
                // Stop watching rather than re-firing the recovery every tick;
                // the writer's own disarm would get here anyway if it returns.
                deadlineNs = 0L
                armedSocket = null
            }
        }
    }

    /**
     * A repeating poll exists only while the watchdog has been armed at least
     * once, and it stops after a long idle cooldown. Healthy high-rate traffic
     * reuses the same task, so it adds no per-packet scheduler churn.
     */
    private fun stopTicker() {
        ticker?.cancel(false)
        ticker = null
    }

    private companion object {
        const val DEFAULT_POLL_INTERVAL_MS = 1_000L
        /** Idle polls before an unused watchdog stops its repeating task. */
        const val IDLE_POLLS_BEFORE_STOP = 60

        /**
         * One scheduler thread is shared by every watchdog in the process. The
         * callbacks are non-blocking (identity checks plus a socket close), so a
         * single thread cannot starve one channel's recovery behind another's.
         */
        val SCHEDULER: ScheduledThreadPoolExecutor =
            ScheduledThreadPoolExecutor(1) { runnable ->
                Thread(runnable, "SocketWriteWatchdog").apply { isDaemon = true }
            }.apply {
                removeOnCancelPolicy = true
                setExecuteExistingDelayedTasksAfterShutdownPolicy(false)
                setContinueExistingPeriodicTasksAfterShutdownPolicy(false)
            }
    }
}
