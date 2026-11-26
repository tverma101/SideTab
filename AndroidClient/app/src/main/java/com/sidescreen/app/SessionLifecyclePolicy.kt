package com.sidescreen.app

/**
 * Pure policy for Android suspend/wake behavior.
 *
 * This deliberately contains no Activity, socket, WakeLock, decoder, or
 * Surface code. SessionController remains the single state owner; this policy
 * only classifies why the previous session ended and whether wake/foreground
 * is allowed to start a new attempt.
 */
object SessionLifecyclePolicy {
    enum class EndReason {
        USER_DISCONNECTED,
        HOST_SUSPENDED,
        VIDEO_TRANSPORT_LOST,
        NETWORK_LOST,
        APP_BACKGROUND_RECREATION,
        FATAL_PROTOCOL_ERROR,
        AUTH_REVOKED,
    }

    data class ReconnectContext(
        val pairedHostAvailable: Boolean,
        val appForeground: Boolean,
        val reconnectAlreadyRunning: Boolean,
        val healthySessionExists: Boolean,
        val endReason: EndReason,
        val explicitlySuppressed: Boolean = false,
    )

    fun shouldAutoReconnect(context: ReconnectContext): Boolean {
        if (!context.pairedHostAvailable) return false
        if (!context.appForeground) return false
        if (context.reconnectAlreadyRunning) return false
        if (context.healthySessionExists) return false
        if (context.explicitlySuppressed) return false

        return when (context.endReason) {
            EndReason.HOST_SUSPENDED,
            EndReason.VIDEO_TRANSPORT_LOST,
            EndReason.NETWORK_LOST,
            EndReason.APP_BACKGROUND_RECREATION -> true

            EndReason.USER_DISCONNECTED,
            EndReason.FATAL_PROTOCOL_ERROR,
            EndReason.AUTH_REVOKED -> false
        }
    }

    /**
     * SideScreen owns keep-awake only while current-generation pixels are
     * actually being presented. Suspending, reconnecting, and disconnected
     * states must allow Android's normal screen timeout to take over.
     */
    fun shouldKeepScreenOn(streamingCurrentGeneration: Boolean): Boolean =
        streamingCurrentGeneration

    /** Capped exponential retry delay. Callers add a small random jitter so
     * several tablets waking together do not synchronize their TCP attempts. */
    fun reconnectDelayMs(attempt: Int, jitterMs: Long = 0L): Long {
        val normalizedAttempt = attempt.coerceAtLeast(1)
        val exponent = (normalizedAttempt - 1).coerceAtMost(6)
        val base = (500L shl exponent).coerceAtMost(30_000L)
        return (base + jitterMs.coerceIn(0L, base / 4L)).coerceAtMost(30_000L)
    }
}
