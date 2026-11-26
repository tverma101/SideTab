package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class USBReconnectPolicyTest {
    private val t0 = 1_000L

    @Test
    fun `an eligible live drop arms and consumes one attempt`() {
        val policy = USBReconnectPolicy(maxAttempts = 3, windowMs = 60_000L)

        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
        assertTrue(policy.recordAttempt(t0))
    }

    @Test
    fun `an ineligible drop disarms recovery so no attempt can be consumed`() {
        val policy = USBReconnectPolicy(maxAttempts = 3, windowMs = 60_000L)

        // User Disconnect, background, screen-off and a replaced generation all
        // arrive here as eligible=false.
        assertFalse(policy.shouldAttemptResume(eligible = false, nowMs = t0))
        assertFalse(policy.recordAttempt(t0))
    }

    @Test
    fun `budget is finite`() {
        val policy = USBReconnectPolicy(maxAttempts = 2, windowMs = 60_000L)

        repeat(2) {
            assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
            assertTrue(policy.recordAttempt(t0))
        }

        assertTrue(policy.spent())
        assertFalse(policy.recordAttempt(t0))
        assertFalse(policy.shouldAttemptResume(eligible = true, nowMs = t0))
    }

    @Test
    fun `the grace delay cannot extend an outage past its window`() {
        val policy = USBReconnectPolicy(maxAttempts = 4, windowMs = 10_000L)

        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
        // 2.5s grace plus a slow connect attempt landed after the window.
        assertFalse(policy.recordAttempt(t0 + 10_500L))
    }

    @Test
    fun `a session that streamed for hours can still resume on its first drop`() {
        val policy = USBReconnectPolicy(maxAttempts = 4, windowMs = 60_000L)

        // Connected hours ago. The recovery window must not have started then,
        // or it would already be expired at the moment of the drop.
        policy.onConnected()
        val manyHoursLater = t0 + 6L * 60 * 60 * 1000

        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = manyHoursLater))
        assertTrue(policy.recordAttempt(manyHoursLater))
    }

    @Test
    fun `a 60s outage permits at most four attempts then stops`() {
        val policy = USBReconnectPolicy(maxAttempts = 4, windowMs = 60_000L)
        val drop = t0
        var now = drop

        repeat(4) {
            assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = now))
            now += 2_500L
            assertTrue(policy.recordAttempt(now))
        }

        assertTrue(policy.spent())
        assertFalse(policy.shouldAttemptResume(eligible = true, nowMs = now))
    }

    @Test
    fun `a successful reconnect restores the budget for a later drop`() {
        val policy = USBReconnectPolicy(maxAttempts = 1, windowMs = 60_000L)
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
        assertTrue(policy.recordAttempt(t0))
        assertFalse(policy.shouldAttemptResume(eligible = true, nowMs = t0))

        policy.onConnected()

        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0 + 500L))
    }

    @Test
    fun `session end clears budget window and arming`() {
        val policy = USBReconnectPolicy(maxAttempts = 1, windowMs = 60_000L)
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
        assertTrue(policy.recordAttempt(t0))
        assertFalse(policy.shouldAttemptResume(eligible = true, nowMs = t0))

        policy.onSessionEnded()

        assertFalse(policy.recordAttempt(t0))
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
    }

    @Test
    fun `resume waits back off and are capped`() {
        val policy = USBReconnectPolicy(maxAttempts = 8, windowMs = 60_000L)
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))

        val delays = mutableListOf<Long>()
        repeat(5) {
            delays += policy.nextDelayMs()
            assertTrue(policy.recordAttempt(t0))
        }

        assertEquals(listOf(2_500L, 5_000L, 10_000L, 10_000L, 10_000L), delays)
    }

    @Test
    fun `the default budget outlasts a Mac app relaunch`() {
        // While the Mac app is down every attempt fails at once, so the outage
        // is covered only by the waits. A relaunch or reinstall takes ~30-45 s.
        val policy = USBReconnectPolicy()
        var now = t0
        var lastAttemptAt = t0
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = now))
        while (true) {
            now += policy.nextDelayMs()
            if (!policy.recordAttempt(now)) break
            lastAttemptAt = now
        }

        assertTrue("last attempt at ${lastAttemptAt - t0} ms", lastAttemptAt - t0 >= 45_000L)
        assertTrue(lastAttemptAt - t0 <= 60_000L)
        assertFalse(policy.shouldAttemptResume(eligible = true, nowMs = now))
    }

    @Test
    fun `reconnect restores the short first wait`() {
        val policy = USBReconnectPolicy()
        assertTrue(policy.shouldAttemptResume(eligible = true, nowMs = t0))
        repeat(3) { assertTrue(policy.recordAttempt(t0)) }

        policy.onConnected()

        assertEquals(2_500L, policy.nextDelayMs())
    }
}
