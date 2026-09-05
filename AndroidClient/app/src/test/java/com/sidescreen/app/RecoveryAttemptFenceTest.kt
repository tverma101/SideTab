package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryAttemptFenceTest {
    @Test
    fun newerAttemptInvalidatesOlderCallback() {
        val fence = RecoveryAttemptFence()
        val first = fence.begin()
        val second = fence.begin()

        assertFalse(fence.isCurrent(first))
        assertTrue(fence.isCurrent(second))
    }

    @Test
    fun explicitInvalidationCancelsOutstandingCallback() {
        val fence = RecoveryAttemptFence()
        val attempt = fence.begin()

        fence.invalidate()

        assertFalse(fence.isCurrent(attempt))
    }
}
