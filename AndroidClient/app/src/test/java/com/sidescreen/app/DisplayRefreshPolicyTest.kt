package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayRefreshPolicyTest {
    @Test
    fun picksHighestSupportedRateAtOrBelow120() {
        assertEquals(
            120f,
            DisplayRefreshPolicy.choosePreferredRate(listOf(60f, 90f, 120f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun doesNotInvent120On60_90_144Panel() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.choosePreferredRate(listOf(60f, 90f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun supportsNonStandard96HzPanelMode() {
        assertEquals(
            96f,
            DisplayRefreshPolicy.choosePreferredRate(listOf(60f, 96f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun acceptsFractional120ClassModeWithinTolerance() {
        assertEquals(
            120.0f,
            DisplayRefreshPolicy.choosePreferredRate(listOf(59.94f, 120.0f, 144f), 59.94f),
            0.001f,
        )
    }

    @Test
    fun preservesCurrentModeWhenNoCandidateFitsCeiling() {
        assertEquals(
            144f,
            DisplayRefreshPolicy.choosePreferredRate(listOf(144f), 144f),
            0.001f,
        )
    }

    @Test
    fun ignoresInvalidRates() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.choosePreferredRate(
                listOf(Float.NaN, -1f, 0f, 90f, Float.POSITIVE_INFINITY),
                60f,
            ),
            0.001f,
        )
    }

    @Test
    fun customCeilingNeverExceedsRequestedMaximum() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.choosePreferredRate(
                sameResolutionRates = listOf(60f, 90f, 120f),
                currentRate = 60f,
                maxStreamRate = 90f,
            ),
            0.001f,
        )
    }
}
