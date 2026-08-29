package com.sidescreen.app

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
    }

    @Test
    fun keepScreenOnBelongsOnlyToCurrentStreamingSession() {
        assertTrue(SessionLifecyclePolicy.shouldKeepScreenOn(true))
        assertFalse(SessionLifecyclePolicy.shouldKeepScreenOn(false))
    }
}
