package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionLifecyclePolicyTest {
    @Test
    fun hostSuspendAllowsWakeReconnectWhenPairedAndForeground() {
        val context =
            SessionLifecyclePolicy.ReconnectContext(
                pairedHostAvailable = true,
                appForeground = true,
                reconnectAlreadyRunning = false,
                healthySessionExists = false,
                endReason = SessionLifecyclePolicy.EndReason.HOST_SUSPENDED,
            )

        assertTrue(SessionLifecyclePolicy.shouldAutoReconnect(context))
    }

    @Test
    fun explicitUserDisconnectNeverAutoReconnects() {
        val context =
            SessionLifecyclePolicy.ReconnectContext(
                pairedHostAvailable = true,
                appForeground = true,
                reconnectAlreadyRunning = false,
                healthySessionExists = false,
                endReason = SessionLifecyclePolicy.EndReason.USER_DISCONNECTED,
            )

        assertFalse(SessionLifecyclePolicy.shouldAutoReconnect(context))
    }

    @Test
    fun reconnectIsSuppressedWhenAnotherAttemptOrHealthySessionExists() {
        val base =
            SessionLifecyclePolicy.ReconnectContext(
                pairedHostAvailable = true,
                appForeground = true,
                reconnectAlreadyRunning = false,
                healthySessionExists = false,
                endReason = SessionLifecyclePolicy.EndReason.NETWORK_LOST,
            )

        assertFalse(
            SessionLifecyclePolicy.shouldAutoReconnect(
                base.copy(reconnectAlreadyRunning = true),
            ),
        )
        assertFalse(
            SessionLifecyclePolicy.shouldAutoReconnect(
                base.copy(healthySessionExists = true),
            ),
        )
        assertFalse(
            SessionLifecyclePolicy.shouldAutoReconnect(
                base.copy(explicitlySuppressed = true),
            ),
        )
    }

    @Test
    fun keepScreenOnBelongsOnlyToCurrentStreamingSession() {
        assertTrue(SessionLifecyclePolicy.shouldKeepScreenOn(true))
        assertFalse(SessionLifecyclePolicy.shouldKeepScreenOn(false))
    }

    @Test
    fun reconnectBackoffIsBoundedAndMonotonic() {
        val delays = (1..12).map { SessionLifecyclePolicy.reconnectDelayMs(it) }

        assertEquals(500L, delays.first())
        assertTrue(delays.zipWithNext().all { (left, right) -> right >= left })
        assertTrue(delays.all { it in 500L..30_000L })
        assertEquals(30_000L, delays.last())
        assertEquals(30_000L, SessionLifecyclePolicy.reconnectDelayMs(12, jitterMs = 10_000L))
    }
}
