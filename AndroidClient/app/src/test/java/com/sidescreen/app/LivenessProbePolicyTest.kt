package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LivenessProbePolicyTest {
    @Test
    fun backgroundedProbeCannotExpireAHealthyTransport() {
        assertFalse(
            LivenessProbePolicy.isExpired(
                sentAtNs = 1_000L,
                nowNs = 20_000L,
                timeoutNs = 5_000L,
                paused = true,
            ),
        )
    }

    @Test
    fun activeProbeExpiresOnlyAfterItsTimeout() {
        assertFalse(
            LivenessProbePolicy.isExpired(
                sentAtNs = 1_000L,
                nowNs = 6_000L,
                timeoutNs = 5_000L,
                paused = false,
            ),
        )
        assertTrue(
            LivenessProbePolicy.isExpired(
                sentAtNs = 1_000L,
                nowNs = 6_001L,
                timeoutNs = 5_000L,
                paused = false,
            ),
        )
    }

    @Test
    fun invalidClockOrMissingProbeDoesNotExpire() {
        assertFalse(LivenessProbePolicy.isExpired(0L, 9_000L, 5_000L, paused = false))
        assertFalse(LivenessProbePolicy.isExpired(9_000L, 8_000L, 5_000L, paused = false))
    }
}
