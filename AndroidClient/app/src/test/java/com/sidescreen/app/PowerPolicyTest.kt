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

    @Test
    fun wirelessStreamingKeepsTheSeamless60HzHintEvenWhenPowered() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                    wireless = true,
                ),
            )

        assertEquals(WirelessFreshnessPolicy.TARGET_FRAME_RATE.toFloat(), decision.requestedRefreshRateHz, 0f)
        assertTrue(decision.keepScreenOn)
        assertTrue(decision.seamlessOnly)
        assertEquals("wireless", decision.reason)
    }

    @Test
    fun wiredRequestsMayForceAModeChange() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = 120f,
                ),
            )

        assertFalse(decision.seamlessOnly)
    }

    @Test
    fun unknownPanelLimitFallsBackTo60Hz() {
        val decision =
            PowerPolicy.decide(
                PowerPolicyInput(
                    streaming = true,
                    foreground = true,
                    interactive = true,
                    externallyPowered = true,
                    powerSaveMode = false,
                    maxRefreshRateHz = Float.NaN,
                ),
            )

        assertEquals(60f, decision.requestedRefreshRateHz, 0f)
    }

    @Test
    fun idleDisconnectKeepsTheConfiguredWindowOnExternalPower() {
        assertEquals(300, PowerPolicy.idleDisconnectSecs(300, externallyPowered = true))
    }

    @Test
    fun idleDisconnectIsCappedOnBattery() {
        assertEquals(30, PowerPolicy.idleDisconnectSecs(300, externallyPowered = false))
        // A shorter configured window is never lengthened by the cap.
        assertEquals(15, PowerPolicy.idleDisconnectSecs(15, externallyPowered = false))
    }

    @Test
    fun idleDisconnectHasAFloor() {
        assertEquals(10, PowerPolicy.idleDisconnectSecs(0, externallyPowered = true))
        assertEquals(10, PowerPolicy.idleDisconnectSecs(-5, externallyPowered = false))
    }
}
