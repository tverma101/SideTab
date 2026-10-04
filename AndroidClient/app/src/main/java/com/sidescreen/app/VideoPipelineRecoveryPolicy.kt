package com.sidescreen.app

/**
 * Decides whether a failed video pipeline gets rebuilt, and stops rebuilding
 * once the budget is gone so the user sees an explanation instead of a black
 * screen forever.
 *
 * The budget is strictly finite for a continuous outage: it is spent by
 * failures and only returned by [onOutputProgress], which the Activity calls
 * from the decoder's real rendered-output callback. It is deliberately NOT
 * refilled by the passage of time — a window-based refill would let a decoder
 * that configures cleanly and never emits a frame retry forever.
 */
internal class VideoPipelineRecoveryPolicy(
    private val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS,
) {
    private var attempts = 0

    /** Attempts consumed since the last proven output. Mirrors what is running now. */
    val attemptCount: Int get() = attempts

    /** Next attempt number, 1-based. */
    fun nextAttemptNumber(): Int = attempts + 1

    /** True when there is budget left to tear this pipeline down and rebuild. */
    fun shouldRecover(): Boolean = attempts < maxAttempts

    /**
     * Consume one rebuild attempt. Call only after [shouldRecover] returned
     * true, so this always succeeds and cannot be forgotten silently.
     */
    fun recordFailure() {
        attempts++
    }

    /**
     * The decoder produced a real rendered output frame. That is the only proof
     * a pipeline works, so it returns the full budget; a session that recovered
     * must not inherit an old failure's exhaustion.
     */
    fun onOutputProgress() {
        attempts = 0
    }

    /** A new session or a manual restart starts from a clean budget. */
    fun reset() {
        attempts = 0
    }

    /** Backoff before the next rebuild so a hard failure cannot spin the UI thread. */
    fun delayForAttempt(attempt: Int): Long =
        (BASE_DELAY_MS shl (attempt - 1).coerceIn(0, 4)).coerceAtMost(MAX_DELAY_MS)

    private companion object {
        const val DEFAULT_MAX_ATTEMPTS = 5
        const val BASE_DELAY_MS = 250L
        const val MAX_DELAY_MS = 4_000L
    }
}
