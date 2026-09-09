package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WirelessRecoveryActionsTest {
    @Test
    fun cachedPairingKeepsReconnectPrimaryAndQrSecondary() {
        val actions = WirelessRecoveryActions.forState(hasPairing = true, requiresRePair = false)

        assertTrue(actions.reconnectVisible)
        assertEquals(WirelessRecoveryActions.SCAN_QR_INSTEAD_LABEL, actions.rescanLabel)
    }

    @Test
    fun rejectedTokenRequiresQrAndHidesReconnect() {
        val actions = WirelessRecoveryActions.forState(hasPairing = true, requiresRePair = true)

        assertFalse(actions.reconnectVisible)
        assertEquals(WirelessRecoveryActions.SCAN_QR_LABEL, actions.rescanLabel)
    }

    @Test
    fun noPairingStartsWithQr() {
        val actions = WirelessRecoveryActions.forState(hasPairing = false, requiresRePair = false)

        assertFalse(actions.reconnectVisible)
        assertEquals(WirelessRecoveryActions.SCAN_QR_LABEL, actions.rescanLabel)
    }
}
