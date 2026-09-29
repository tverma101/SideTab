package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessFreshnessPolicyTest {
    @Test
    fun targetsSixtyFramesPerSecondWithTwoIntervalAgeBudget() {
        assertEquals(60, WirelessFreshnessPolicy.TARGET_FRAME_RATE)
        assertEquals(16_666_666L, WirelessFreshnessPolicy.FRAME_INTERVAL_NS)
        assertEquals(33_333_332L, WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS)
    }

    @Test
    fun firstOutputAlwaysRendersAndFreshOutputRenders() {
        assertTrue(WirelessFreshnessPolicy.shouldRender(10_000_000L, isFirstFrame = true))
        assertTrue(
            WirelessFreshnessPolicy.shouldRender(
                WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS,
                isFirstFrame = false,
            ),
        )
    }

    @Test
    fun outputOlderThanTwoIntervalsIsDropped() {
        assertFalse(
            WirelessFreshnessPolicy.shouldRender(
                WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS + 1,
                isFirstFrame = false,
            ),
        )
    }
}
