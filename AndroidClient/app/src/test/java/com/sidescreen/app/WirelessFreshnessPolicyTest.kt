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

    // MARK: - The caller's contract
    //
    // The policy above was always correct. The defect was in the decoder, which
    // never called it for the stalest frames: `!hasValidLatency` short-circuited
    // to "render". These pin the decision the decoder actually makes, which was
    // previously untestable because it lived inline in a MediaCodec callback.

    private val reasonable = 2_000_000_000L
    private val usbRender = 250_000_000L

    /**
     * The regression: an output older than the decoder's own "reasonable"
     * ceiling — roughly sixty times the wireless budget — was the one case that
     * guaranteed a render. It is now the case that guarantees a drop.
     */
    @Test
    fun wirelessOutputOlderThanTheDecoderCeilingIsDroppedNotRendered() {
        assertFalse(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = reasonable + 1,
                hasValidLatency = false,
                isFirstOutput = false,
                wireless = true,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }

    @Test
    fun wirelessOutputWithinBudgetStillRenders() {
        assertTrue(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS,
                hasValidLatency = true,
                isFirstOutput = false,
                wireless = true,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }

    @Test
    fun wirelessOutputJustOverBudgetIsDropped() {
        assertFalse(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS + 1,
                hasValidLatency = true,
                isFirstOutput = false,
                wireless = true,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }

    /** The first output must render regardless, or a session never starts. */
    @Test
    fun firstOutputRendersEvenWhenWildlyStale() {
        for (wireless in listOf(true, false)) {
            assertTrue(
                WirelessFreshnessPolicy.shouldRenderOutput(
                    decodedLatencyNs = Long.MAX_VALUE,
                    hasValidLatency = false,
                    isFirstOutput = true,
                    wireless = wireless,
                    maxReasonableLatencyNs = reasonable,
                    maxRenderLatencyNs = usbRender,
                ),
            )
        }
    }

    /** USB keeps its looser ceiling; that is intentional, not the same bug. */
    @Test
    fun usbKeepsItsLooserLatencyCeiling() {
        assertTrue(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = usbRender,
                hasValidLatency = true,
                isFirstOutput = false,
                wireless = false,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
        assertFalse(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = usbRender + 1,
                hasValidLatency = true,
                isFirstOutput = false,
                wireless = false,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }

    /**
     * Regression, found by reviewing the first implementation of this policy:
     * the USB arm read `!hasValidLatency || decodedLatencyNs <= maxRenderLatencyNs`,
     * so an uninterpretable age — one that cannot be compared to the clock at
     * all — was rendered. That is the exact opposite of the arm's own KDoc, and
     * it is reachable on USB after any stall past the decoder's ceiling. A
     * looser bound is still a bound.
     */
    @Test
    fun usbAlsoDropsAnUninterpretableLatency() {
        assertFalse(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = reasonable + 1,
                hasValidLatency = false,
                isFirstOutput = false,
                wireless = false,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }

    /** A clock reading behind the presentation timestamp is not interpretable. */
    @Test
    fun negativeLatencyIsNotInterpretable() {
        assertFalse(
            WirelessFreshnessPolicy.shouldRenderOutput(
                decodedLatencyNs = -1L,
                hasValidLatency = false,
                isFirstOutput = false,
                wireless = true,
                maxReasonableLatencyNs = reasonable,
                maxRenderLatencyNs = usbRender,
            ),
        )
    }
}
