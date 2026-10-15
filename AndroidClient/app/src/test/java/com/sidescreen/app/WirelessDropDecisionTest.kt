package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class WirelessDropDecisionTest {
    @Test
    fun noPairingIsTerminalForTheCaller() {
        assertEquals(
            WirelessDropDecision.Action.NO_PAIRING,
            WirelessDropDecision.forDrop(hasPairing = false, recoveryArmed = true, recoveryInFlight = false),
        )
    }

    @Test
    fun armedDropStartsOneBoundedRecovery() {
        assertEquals(
            WirelessDropDecision.Action.START_RECOVERY,
            WirelessDropDecision.forDrop(hasPairing = true, recoveryArmed = true, recoveryInFlight = false),
        )
    }

    /**
     * The terminal status(false) callback and the thrown connect error both
     * arrive for one outage. The second one must not replace the in-flight
     * "Finding your Mac…" panel with the network repair panel.
     */
    @Test
    fun dropDuringInFlightRecoveryLeavesConnectingAlone() {
        assertEquals(
            WirelessDropDecision.Action.AWAIT_PENDING_RECOVERY,
            WirelessDropDecision.forDrop(hasPairing = true, recoveryArmed = true, recoveryInFlight = true),
        )
        assertEquals(
            WirelessDropDecision.Action.AWAIT_PENDING_RECOVERY,
            WirelessDropDecision.forDrop(hasPairing = true, recoveryArmed = false, recoveryInFlight = true),
        )
    }

    @Test
    fun spentRecoveryShowsNetworkRepair() {
        assertEquals(
            WirelessDropDecision.Action.SHOW_REPAIR,
            WirelessDropDecision.forDrop(hasPairing = true, recoveryArmed = false, recoveryInFlight = false),
        )
    }

    @Test
    fun noPairingBeatsAnInFlightRecovery() {
        // Forget Pairing during a recovery clears the entry; the safe terminal
        // state is the caller's no-pairing UI, not a repair panel for a pairing
        // that is gone.
        assertEquals(
            WirelessDropDecision.Action.NO_PAIRING,
            WirelessDropDecision.forDrop(hasPairing = false, recoveryArmed = false, recoveryInFlight = true),
        )
    }
}
