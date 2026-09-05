package com.sidescreen.app

import org.junit.Assert.assertEquals
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
}
