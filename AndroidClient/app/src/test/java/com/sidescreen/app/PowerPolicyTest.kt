package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerPolicyTest {
    @Test
    fun poweredStreamingKeeps120HzRequestDuringBatterySaver() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = true,
                    maxRefreshRateHz = 120f,
                ),
            )

        assertEquals(120f, decision.requestedRefreshRateHz, 0f)
        assertTrue(decision.keepScreenOn)
        assertTrue(decision.requestsHighRefreshRate)
        assertEquals("powered-battery-saver", decision.reason)
    }

    @Test
    fun batteryStreamingFallsBackTo60Hz() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = false,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                ),
            )

        assertEquals(60f, decision.requestedRefreshRateHz, 0f)
        assertTrue(decision.keepScreenOn)
        assertFalse(decision.requestsHighRefreshRate)
    }

    @Test
    fun idleOrBackgroundActivityReleasesPowerRequests() {
        val idle =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = false,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                ),
            )
        val background =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = false,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                ),
            )

        assertEquals(0f, idle.requestedRefreshRateHz, 0f)
        assertFalse(idle.keepScreenOn)
        assertEquals(0f, background.requestedRefreshRateHz, 0f)
        assertFalse(background.keepScreenOn)
    }

    @Test
    fun screenOffStreamingReleasesPowerRequests() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = false,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                ),
            )

        assertEquals(0f, decision.requestedRefreshRateHz, 0f)
        assertFalse(decision.keepScreenOn)
        assertEquals("background-or-screen-off", decision.reason)
    }

    @Test
    fun poweredStreamingRespectsLowerPanelLimit() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = true,
                    maxRefreshRateHz = 90f,
                ),
            )

        assertEquals(90f, decision.requestedRefreshRateHz, 0f)
        assertFalse(decision.requestsHighRefreshRate)
    }
}
