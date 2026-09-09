package com.sidescreen.app

/**
 * Presentation rules for a failed wireless connection.
 *
 * A known pairing is recoverable without a camera. Re-pairing is only required
 * after the Mac rejects the saved token, or when there is no pairing at all.
 */
data class WirelessRecoveryActions(
    val reconnectVisible: Boolean,
    val rescanLabel: String,
) {
    companion object {
        const val SCAN_QR_LABEL = "Scan QR Code"
        const val SCAN_QR_INSTEAD_LABEL = "Scan QR instead"

        fun forState(
            hasPairing: Boolean,
            requiresRePair: Boolean,
        ): WirelessRecoveryActions {
            val canReconnect = hasPairing && !requiresRePair
            return WirelessRecoveryActions(
                reconnectVisible = canReconnect,
                rescanLabel = if (canReconnect) SCAN_QR_INSTEAD_LABEL else SCAN_QR_LABEL,
            )
        }
    }
}
