package com.sidescreen.app

/** Inputs used to choose the Android client's app-scoped power policy. */
internal data class PowerPolicyInput(
    val streaming: Boolean,
    val foreground: Boolean,
    val interactive: Boolean,
    val externallyPowered: Boolean,
    val powerSaveMode: Boolean,
    val maxRefreshRateHz: Float,
    /** Wireless streams are bounded at [WirelessFreshnessPolicy.TARGET_FRAME_RATE]. */
    val wireless: Boolean = false,
)

/** The display and keep-awake requests that SideTab is allowed to make. */
internal data class PowerPolicyDecision(
    val requestedRefreshRateHz: Float,
    val keepScreenOn: Boolean,
    val reason: String,
    /**
     * Only switch panel modes when Android can do it without a visible blank.
     * Wireless keeps its existing seamless-only hint; a USB request is
     * allowed to force the mode change.
     */
    val seamlessOnly: Boolean = false,
) {
    val requestsHighRefreshRate: Boolean
        get() = requestedRefreshRateHz >= PowerPolicy.HIGH_REFRESH_RATE_HZ
}

/**
 * Keeps SideTab responsive without changing the power policy of Android's
 * other apps. Battery Saver is deliberately not disabled here: when the
 * tablet is externally powered, the video surface can still request 120 Hz;
 * on battery, an active stream is limited to a 60 Hz request. A wireless
 * stream never carries more than 60 FPS, so it never asks for more.
 */
internal object PowerPolicy {
    const val HIGH_REFRESH_RATE_HZ = 120f
    const val BATTERY_REFRESH_RATE_HZ = 60f

    /** Default for `settings put system sidescreen_auto_disconnect_secs`. */
    const val DEFAULT_IDLE_DISCONNECT_SECS = 300

    /** On battery an unattended session gives up this quickly at most. */
    const val BATTERY_IDLE_DISCONNECT_CAP_SECS = 30

    /** Lower bound applied to any configured idle window. */
    const val MIN_IDLE_DISCONNECT_SECS = 10

    fun decide(input: PowerPolicyInput): PowerPolicyDecision {
        if (!input.streaming) {
            return PowerPolicyDecision(
                requestedRefreshRateHz = 0f,
                keepScreenOn = false,
                reason = "idle",
            )
        }

        if (!input.foreground || !input.interactive) {
            return PowerPolicyDecision(
                requestedRefreshRateHz = 0f,
                keepScreenOn = false,
                reason = "background-or-screen-off",
            )
        }

        val maxRefreshRate =
            input.maxRefreshRateHz
                .takeIf { it.isFinite() && it > 0f }
                ?: BATTERY_REFRESH_RATE_HZ

        if (input.wireless) {
            return PowerPolicyDecision(
                requestedRefreshRateHz =
                    minOf(WirelessFreshnessPolicy.TARGET_FRAME_RATE.toFloat(), maxRefreshRate),
                keepScreenOn = true,
                reason = "wireless",
                seamlessOnly = true,
            )
        }

        val poweredTarget = minOf(HIGH_REFRESH_RATE_HZ, maxRefreshRate)
        if (input.externallyPowered && poweredTarget >= 90f) {
            return PowerPolicyDecision(
                requestedRefreshRateHz = poweredTarget,
                keepScreenOn = true,
                reason = if (input.powerSaveMode) "powered-battery-saver" else "powered",
            )
        }

        return PowerPolicyDecision(
            requestedRefreshRateHz = minOf(BATTERY_REFRESH_RATE_HZ, maxRefreshRate),
            keepScreenOn = true,
            reason = if (input.powerSaveMode) "battery-saver" else "battery",
        )
    }

    /**
     * How long an unattended (backgrounded or screen-off) session may stay
     * connected. External power keeps the configured window; on battery it is
     * capped so an unused tablet can reach Android's normal idle/Doze path.
     */
    fun idleDisconnectSecs(
        configuredSecs: Int,
        externallyPowered: Boolean,
    ): Int {
        val configured = configuredSecs.coerceAtLeast(MIN_IDLE_DISCONNECT_SECS)
        return if (externallyPowered) configured else minOf(configured, BATTERY_IDLE_DISCONNECT_CAP_SECS)
    }
}
