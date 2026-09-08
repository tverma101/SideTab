package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayRefreshPolicyTest {
    @Test
    fun modernAndroidExpresses120IntentDirectly() {
        assertEquals(120f, DisplayRefreshPolicy.modernPreferredRate(), 0.001f)
    }

    @Test
    fun legacyExact120ModeWins() {
        assertEquals(
            120f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(60f, 90f, 120f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun legacy60_90_144PanelChooses144AsClosestTo120() {
        assertEquals(
            144f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(60f, 90f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun legacyTiePrefersHigherRefreshInsteadOfCappingPresentation() {
        // 96 and 144 are both 24 Hz away from the 120-FPS intent.
        assertEquals(
            144f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(60f, 96f, 144f), 60f),
            0.001f,
        )
    }

    @Test
    fun legacyPanelWithNothingAbove90StillChooses90() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(60f, 90f), 60f),
            0.001f,
        )
    }

    @Test
    fun legacyFractional120ClassModeBeats144() {
        assertEquals(
            119.88f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(59.94f, 119.88f, 144f), 59.94f),
            0.001f,
        )
    }

    @Test
    fun legacySingle144ModeStays144() {
        assertEquals(
            144f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(listOf(144f), 144f),
            0.001f,
        )
    }

    @Test
    fun ignoresInvalidRates() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(
                listOf(Float.NaN, -1f, 0f, 90f, Float.POSITIVE_INFINITY),
                60f,
            ),
            0.001f,
        )
    }

    @Test
    fun customIntentUsesClosestAdvertisedMode() {
        assertEquals(
            90f,
            DisplayRefreshPolicy.chooseLegacyPreferredRate(
                sameResolutionRates = listOf(60f, 90f, 120f),
                currentRate = 60f,
                intendedRate = 90f,
            ),
            0.001f,
        )
    }
}
