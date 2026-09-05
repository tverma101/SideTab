package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessReconnectPolicyTest {
    @Test
    fun reconnectBackoffStartsFastAndCapsAtFiveSeconds() {
        val expected = listOf(250L, 500L, 1000L, 2000L, 4000L, 5000L, 5000L, 5000L)
        val actual = (1..expected.size).map { attempt -> StreamClient.reconnectDelayMs(attempt) }
        assertEquals(expected, actual)
    }

    @Test
    fun invalidAttemptStillReturnsSafeInitialDelay() {
        assertEquals(250L, StreamClient.reconnectDelayMs(0))
        assertEquals(250L, StreamClient.reconnectDelayMs(-100))
    }

    @Test
    fun quietVideoGapRequiresStrictlyMoreThanFreshnessWindow() {
        val previous = 10_000_000_000L
        assertFalse(StreamClient.isLongVideoGap(previous, previous + 6_000_000_000L))
        assertTrue(StreamClient.isLongVideoGap(previous, previous + 6_000_000_001L))
    }

    @Test
    fun missingOrReversedVideoTimestampIsNeverQuietGap() {
        assertFalse(StreamClient.isLongVideoGap(0L, 7_000_000_000L))
        assertFalse(StreamClient.isLongVideoGap(7_000_000_000L, 4_000_000_000L))
    }
}
