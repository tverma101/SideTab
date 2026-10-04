package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoPipelineRecoveryPolicyTest {
    @Test
    fun `first failure consumes the first attempt`() {
        val policy = VideoPipelineRecoveryPolicy(maxAttempts = 3)

        assertTrue(policy.shouldRecover())
        policy.recordFailure()

        assertEquals(1, policy.attemptCount)
        assertEquals(2, policy.nextAttemptNumber())
    }

    @Test
    fun `a continuous outage stops after the budget`() {
        val policy = VideoPipelineRecoveryPolicy(maxAttempts = 5)

        repeat(5) {
            assertTrue(policy.shouldRecover())
            policy.recordFailure()
        }

        assertFalse(policy.shouldRecover())
        assertEquals(5, policy.attemptCount)
    }

    @Test
    fun `only proven output progress restores the budget`() {
        val policy = VideoPipelineRecoveryPolicy(maxAttempts = 2)
        repeat(2) { policy.recordFailure() }
        assertFalse(policy.shouldRecover())

        // A real rendered output is the only signal that ends an outage.
        policy.onOutputProgress()

        assertEquals(0, policy.attemptCount)
        assertTrue(policy.shouldRecover())
    }

    @Test
    fun `reset restores the budget for a new session or manual restart`() {
        val policy = VideoPipelineRecoveryPolicy(maxAttempts = 1)
        policy.recordFailure()
        assertFalse(policy.shouldRecover())

        policy.reset()

        assertTrue(policy.shouldRecover())
    }

    @Test
    fun `delay grows with attempt and is capped`() {
        val policy = VideoPipelineRecoveryPolicy()

        assertEquals(250L, policy.delayForAttempt(1))
        assertEquals(500L, policy.delayForAttempt(2))
        assertEquals(4_000L, policy.delayForAttempt(20))
    }
}
