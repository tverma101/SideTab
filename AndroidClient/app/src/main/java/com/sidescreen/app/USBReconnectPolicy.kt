package com.sidescreen.app

/**
 * Whether the client may auto-resume a USB session that was live and then
 * dropped, and how many further attempts that resume gets.
 *
 * USB has no session-level retry in [StreamClient] (a dropped wired session is
 * terminal by design), yet a wired session can die for a reason the client
 * cannot fix: the Mac's ADB server crashed, its `adb reverse` bridge was torn
 * down, and it repairs itself within about two seconds. Without a bounded
 * resume, that transient host-side fault leaves the tablet permanently black
 * with no in-app path back. With an unbounded resume, a genuinely unplugged
 * tablet would retry forever, so the policy is a finite attempt/time budget
 * that a fresh connection or a user Disconnect resets.
 */
internal class USBReconnectPolicy(
    private val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
    private val windowMs: Long = DEFAULT_WINDOW_MS,
) {
    private var attempts = 0
    private var windowStartedAtMs = 0L
    private var armed = false

    /** True when this outage has consumed the whole resume budget. */
    fun spent(): Boolean = attempts >= maxAttempts

    /**
     * Eligibility is decided by the Activity: only a previously live,
     * foreground, interactive USB session qualifies. The policy owns only the
     * budget for that session.
     */
    fun onSessionDropped(nowMs: Long) {
        if (windowStartedAtMs == 0L) windowStartedAtMs = nowMs
    }

    /**
     * Returns true when this drop should trigger a bounded automatic resume.
     * [eligible] must be false after a user Disconnect, on background, or on
     * screen-off; the policy refuses those without consulting the budget.
     */
    fun shouldAttemptResume(
        eligible: Boolean,
        nowMs: Long,
    ): Boolean {
        // An ineligible drop (user Disconnect, background, screen-off, wireless
        // session, replaced generation) disarms recovery: no armed attempt may
        // later consume budget.
        if (!eligible) {
            armed = false
            return false
        }
        armed = true
        onSessionDropped(nowMs)
        return attempts < maxAttempts && nowMs - windowStartedAtMs <= windowMs
    }

    /**
     * Consume one resume attempt. The window is re-checked here, not only at
     * arming time, because the caller waits a grace period before it runs and
     * that wait must not be able to extend an outage past its budget.
     */
    fun recordAttempt(nowMs: Long): Boolean {
        if (!armed) return false
        onSessionDropped(nowMs)
        if (attempts >= maxAttempts || nowMs - windowStartedAtMs > windowMs) return false
        attempts++
        return true
    }

    /** Attempts consumed so far in this outage. */
    val attemptCount: Int get() = attempts

    /**
     * Wait before the next attempt. While the Mac app is down, the tablet-side
     * `adb reverse` listener still accepts the TCP connect and the host side
     * then closes it at once, so every attempt fails within milliseconds. At a
     * flat 2.5 s grace the whole budget was spent ~10 s into the outage, and a
     * Mac app relaunch or reinstall left the tablet disconnected until the
     * user tapped Connect. Doubling the wait up to [MAX_DELAY_MS] spreads the
     * attempts across the whole window instead.
     */
    fun nextDelayMs(): Long {
        val shift = attempts.coerceAtMost(MAX_DELAY_SHIFT)
        return (BASE_DELAY_MS shl shift).coerceAtMost(MAX_DELAY_MS)
    }

    /**
     * A live reconnect (or any fresh user-initiated connect) proves the path
     * works, so the next unrelated drop gets a full budget. The window is left
     * unset on purpose: it must start at the first drop, not at connect time, or
     * a session that streamed for hours would find its recovery window already
     * expired the moment it dropped.
     */
    fun onConnected() {
        attempts = 0
        windowStartedAtMs = 0L
        armed = false
    }

    /** Explicit Disconnect or leaving the session ends automatic recovery. */
    fun onSessionEnded() {
        attempts = 0
        windowStartedAtMs = 0L
        armed = false
    }

    private companion object {
        const val DEFAULT_MAX_ATTEMPTS = 8
        const val DEFAULT_WINDOW_MS = 60_000L
        const val BASE_DELAY_MS = 2_500L
        const val MAX_DELAY_MS = 10_000L
        const val MAX_DELAY_SHIFT = 2
    }
}
