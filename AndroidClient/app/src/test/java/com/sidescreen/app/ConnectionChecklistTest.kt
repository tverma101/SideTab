package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionChecklistTest {
    @Test
    fun unobservableUsbRouteAndMacAreNeverReportedAsPassed() {
        val items = ConnectionChecklist.usb(
            developerModeEnabled = true,
            adbEnabled = true,
            bridge = MacBridgeState.NOT_CHECKED,
        )

        assertEquals(ChecklistEvidence.PASS, items[0].evidence)
        assertEquals(ChecklistEvidence.PASS, items[1].evidence)
        assertEquals(ChecklistEvidence.UNKNOWN, items[2].evidence)
        assertEquals(ChecklistEvidence.UNKNOWN, items[3].evidence)
        assertFalse(items[2].label.contains("connected", ignoreCase = true))
        assertTrue(items[2].label.contains("not verified"))
        assertTrue(items[3].label.contains("not checked"))
    }

    @Test
    fun bridgeEvidenceProgressesFromPendingToPassOrFail() {
        assertEquals(ChecklistEvidence.PENDING, ConnectionChecklist.usb(true, true, MacBridgeState.CONNECTING)[3].evidence)
        assertEquals(ChecklistEvidence.PENDING, ConnectionChecklist.usb(true, true, MacBridgeState.DISPLAY_CONFIGURED)[3].evidence)
        assertEquals(ChecklistEvidence.PASS, ConnectionChecklist.usb(true, true, MacBridgeState.STREAMING)[3].evidence)
        assertEquals(ChecklistEvidence.FAIL, ConnectionChecklist.usb(true, true, MacBridgeState.REJECTED)[3].evidence)
    }

    @Test
    fun routePassRequiresMacAdmissionEvidence() {
        assertEquals(
            ChecklistEvidence.PENDING,
            ConnectionChecklist.usb(true, true, MacBridgeState.SOCKET_OPEN)[2].evidence,
        )
        assertEquals(
            ChecklistEvidence.UNKNOWN,
            ConnectionChecklist.usb(true, true, MacBridgeState.DISPLAY_CONFIGURED)[2].evidence,
        )
        assertEquals(
            ChecklistEvidence.PASS,
            ConnectionChecklist.usb(
                true,
                true,
                MacBridgeState.DISPLAY_CONFIGURED,
                routeAccepted = true,
            )[2].evidence,
        )
        assertEquals(
            ChecklistEvidence.FAIL,
            ConnectionChecklist.usb(true, true, MacBridgeState.REJECTED)[2].evidence,
        )
    }

    @Test
    fun unavailableLocalSettingIsShownAsUnknown() {
        val items = ConnectionChecklist.usb(null, null, MacBridgeState.NOT_CHECKED)

        assertEquals(ChecklistEvidence.UNKNOWN, items[0].evidence)
        assertEquals(ChecklistEvidence.UNKNOWN, items[1].evidence)
        assertTrue(items[0].label.contains("unavailable"))
        assertTrue(items[1].label.contains("unavailable"))
    }
}
