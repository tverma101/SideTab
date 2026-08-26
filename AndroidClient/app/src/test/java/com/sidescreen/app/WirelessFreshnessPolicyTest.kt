package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessFreshnessPolicyTest {
    @Test
    fun `wireless cap remains 60 fps`() {
        assertEquals(60, WirelessFreshnessPolicy.TARGET_FPS)
        assertEquals(WirelessFreshnessPolicy.TARGET_FPS, WirelessTransportProfile.TARGET_FPS)
    }

    @Test
    fun `stale budget is exactly two frame intervals`() {
        assertEquals(
            WirelessFreshnessPolicy.FRAME_INTERVAL_NS * 2,
            WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS,
        )
    }

    @Test
    fun `frame at stale boundary may render but older frame is rejected`() {
        assertTrue(
            WirelessFreshnessPolicy.shouldRender(
                WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS,
                isFirstFrame = false,
            ),
        )
        assertFalse(
            WirelessFreshnessPolicy.shouldRender(
                WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS + 1,
                isFirstFrame = false,
            ),
        )
    }

    @Test
    fun `first frame bypasses stale gate for startup recovery`() {
        assertTrue(
            WirelessFreshnessPolicy.shouldRender(
                500_000_000L,
                isFirstFrame = true,
            ),
        )
    }

    @Test
    fun `paced experiment allows only one extra presentation frame`() {
        assertEquals(1, WirelessFreshnessPolicy.TARGET_EXTRA_PRESENTATION_FRAMES)
    }
}
