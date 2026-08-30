package com.sidescreen.app

/** Evidence level used by the connection panel. Unknown is intentionally not
 * rendered as a failure or a success: an Android device cannot observe the
 * Mac's listener or ADB reverse table without opening a competing connection.
 */
internal enum class ChecklistEvidence {
    PASS,
    FAIL,
    UNKNOWN,
    PENDING,
}

internal data class ChecklistItem(
    val label: String,
    val evidence: ChecklistEvidence,
)

internal enum class MacBridgeState {
    NOT_CHECKED,
    CONNECTING,
    SOCKET_OPEN,
    MODE_ACCEPTED,
    DISPLAY_CONFIGURED,
    STREAMING,
    REJECTED,
    CLOSED_BEFORE_DISPLAY,
    FAILED,
}

/** Pure presentation model for the Android USB checklist. */
internal object ConnectionChecklist {
    fun usb(
        developerModeEnabled: Boolean?,
        adbEnabled: Boolean?,
        bridge: MacBridgeState,
        routeAccepted: Boolean = false,
    ): List<ChecklistItem> =
        listOf(
            setting("Developer settings: enabled", developerModeEnabled),
            setting("USB debugging setting: enabled", adbEnabled),
            routeItem(bridge, routeAccepted),
            bridgeItem(bridge),
        )

    private fun routeItem(
        bridge: MacBridgeState,
        routeAccepted: Boolean,
    ): ChecklistItem =
        when {
            routeAccepted -> ChecklistItem(
                "USB route: Mac accepted loopback/ADB-reverse",
                ChecklistEvidence.PASS,
            )
            bridge == MacBridgeState.CONNECTING || bridge == MacBridgeState.SOCKET_OPEN -> ChecklistItem(
                "USB route: awaiting Mac admission response",
                ChecklistEvidence.PENDING,
            )
            bridge == MacBridgeState.REJECTED -> ChecklistItem(
                "USB route: Mac rejected this mode or route",
                ChecklistEvidence.FAIL,
            )
            else -> ChecklistItem(
                "USB route: not verified by the Mac bridge",
                ChecklistEvidence.UNKNOWN,
            )
        }

    private fun setting(
        label: String,
        enabled: Boolean?,
    ): ChecklistItem =
        when (enabled) {
            true -> ChecklistItem(label, ChecklistEvidence.PASS)
            false -> ChecklistItem(label.replace(": enabled", ": not reported enabled"), ChecklistEvidence.FAIL)
            null -> ChecklistItem(label.replace(": enabled", ": unavailable"), ChecklistEvidence.UNKNOWN)
        }

    private fun bridgeItem(state: MacBridgeState): ChecklistItem =
        when (state) {
            MacBridgeState.NOT_CHECKED -> ChecklistItem(
                "Mac bridge: not checked until you tap Connect",
                ChecklistEvidence.UNKNOWN,
            )
            MacBridgeState.CONNECTING -> ChecklistItem(
                "Mac bridge: connecting; awaiting Mac admission",
                ChecklistEvidence.PENDING,
            )
            MacBridgeState.SOCKET_OPEN -> ChecklistItem(
                "Mac bridge: socket open; waiting for Mac admission",
                ChecklistEvidence.PENDING,
            )
            MacBridgeState.MODE_ACCEPTED -> ChecklistItem(
                "Mac bridge: Mac accepted USB; waiting for display config",
                ChecklistEvidence.PENDING,
            )
            MacBridgeState.DISPLAY_CONFIGURED -> ChecklistItem(
                "Mac bridge: display config received; waiting for first frame",
                ChecklistEvidence.PENDING,
            )
            MacBridgeState.STREAMING -> ChecklistItem(
                "Mac bridge: streaming evidence received",
                ChecklistEvidence.PASS,
            )
            MacBridgeState.REJECTED -> ChecklistItem(
                "Mac bridge: Mac rejected this mode or route",
                ChecklistEvidence.FAIL,
            )
            MacBridgeState.CLOSED_BEFORE_DISPLAY -> ChecklistItem(
                "Mac bridge: closed before display config",
                ChecklistEvidence.FAIL,
            )
            MacBridgeState.FAILED -> ChecklistItem(
                "Mac bridge: connection failed before streaming",
                ChecklistEvidence.FAIL,
            )
        }
}
