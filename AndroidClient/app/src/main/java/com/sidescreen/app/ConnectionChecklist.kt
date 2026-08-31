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
    STREAMING_UNVERIFIED,
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
            bridgeItem(bridge, routeAccepted),
        )

    private fun routeItem(
        bridge: MacBridgeState,
        routeAccepted: Boolean,
    ): ChecklistItem =
        when {
            bridge == MacBridgeState.REJECTED -> ChecklistItem(
                "USB route: Mac rejected this mode or route",
                ChecklistEvidence.FAIL,
            )
            routeAccepted -> ChecklistItem(
                "USB route: Mac accepted loopback/ADB-reverse",
                ChecklistEvidence.PASS,
            )
            bridge == MacBridgeState.CONNECTING || bridge == MacBridgeState.SOCKET_OPEN -> ChecklistItem(
                "USB route: awaiting Mac admission response",
                ChecklistEvidence.PENDING,
            )
            bridge == MacBridgeState.CLOSED_BEFORE_DISPLAY || bridge == MacBridgeState.FAILED -> ChecklistItem(
                "USB route: connection failed before route confirmation",
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

    private fun bridgeItem(
        state: MacBridgeState,
        routeAccepted: Boolean,
    ): ChecklistItem =
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
                if (routeAccepted) {
                    "Mac bridge: display config received; waiting for first frame"
                } else {
                    "Mac bridge: display config received; mode admission unavailable"
                },
                if (routeAccepted) ChecklistEvidence.PENDING else ChecklistEvidence.UNKNOWN,
            )
            MacBridgeState.STREAMING -> ChecklistItem(
                "Mac bridge: streaming evidence received",
                ChecklistEvidence.PASS,
            )
            MacBridgeState.STREAMING_UNVERIFIED -> ChecklistItem(
                "Mac bridge: streaming, but Mac mode admission was not reported",
                ChecklistEvidence.UNKNOWN,
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
