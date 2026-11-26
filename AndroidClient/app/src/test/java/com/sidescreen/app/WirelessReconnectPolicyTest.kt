package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessReconnectPolicyTest {
    @Test
    fun briefWirelessOutageGetsSeveralRecoveryAttempts() {
        assertEquals(8, StreamClient.MAX_WIRELESS_RECONNECT_ATTEMPTS)
    }

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
    fun wirelessKeyframeWatchdogWaitsBeyondTheMacsLongWifiGop() {
        assertEquals(6_000_000_000L, StreamClient.keyframeStaleIntervalNs(wireless = false))
        // Mac: 30 s periodic fallback on Wi-Fi, plus slack.
        assertTrue(StreamClient.keyframeStaleIntervalNs(wireless = true) > 30_000_000_000L)
    }

    /**
     * Wi-Fi silence is routine: the Mac sends nothing for a still desktop and
     * takes its routine keyframe when motion stops. So the "this was just an
     * idle screen, do not touch the keyframe watchdog" verdict has to use the
     * wireless interval. Judged against USB's 6 s, a 7 s pause would count as
     * an idle screen and re-anchor the watchdog on every quiet stretch instead
     * of reporting the stale keyframe it exists to catch.
     */
    @Test
    fun wirelessIdleGapNeedsTheWirelessInterval() {
        val previous = 1_000_000_000L
        // 7 s of quiet: an idle screen on USB, still a keyframe-watchdog gap on Wi-Fi.
        assertTrue(StreamClient.isLongVideoGap(previous, previous + 7_000_000_000L, wireless = false))
        assertFalse(StreamClient.isLongVideoGap(previous, previous + 7_000_000_000L, wireless = true))
        // Past even the Wi-Fi fallback GOP: nothing was sent, so no keyframe was lost.
        assertTrue(StreamClient.isLongVideoGap(previous, previous + 40_000_000_000L, wireless = true))
    }

    @Test
    fun missingOrReversedVideoTimestampIsNeverQuietGap() {
        assertFalse(StreamClient.isLongVideoGap(0L, 7_000_000_000L))
        assertFalse(StreamClient.isLongVideoGap(7_000_000_000L, 4_000_000_000L))
    }
}
