package com.sidescreen.app

/**
 * What a terminal wireless stream loss (or a NetworkUnreachable connect
 * failure) should do with the Wireless tab state machine.
 *
 * The terminal `status(false)` callback and the thrown connect error both land
 * on the main thread for the same outage. Starting one Bonjour recovery is
 * correct; letting the second event race it is not — it replaced the
 * "Finding your Mac…" panel with a "check your network" repair panel while the
 * recovery was still running, then flipped back to Connecting when recovery
 * resolved. A recovery that is already in flight owns the outcome, so a second
 * drop/error signal must leave the CONNECTING state alone.
 */
internal object WirelessDropDecision {
    enum class Action {
        /** No pairing at all; the caller picks its own terminal presentation. */
        NO_PAIRING,

        /** A Bonjour recovery is already running; its outcome owns the UI. */
        AWAIT_PENDING_RECOVERY,

        /** Start the one bounded Bonjour recovery for this connection action. */
        START_RECOVERY,

        /** Recovery is unavailable or spent: show the network repair panel. */
        SHOW_REPAIR,
    }

    fun forDrop(
        hasPairing: Boolean,
        recoveryArmed: Boolean,
        recoveryInFlight: Boolean,
    ): Action =
        when {
            !hasPairing -> Action.NO_PAIRING
            recoveryInFlight -> Action.AWAIT_PENDING_RECOVERY
            recoveryArmed -> Action.START_RECOVERY
            else -> Action.SHOW_REPAIR
        }
}
