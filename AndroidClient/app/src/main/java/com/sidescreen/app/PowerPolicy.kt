package com.sidescreen.app

/** Inputs used to choose the Android client's app-scoped power policy. */
internal data class PowerPolicyInput(
    val streaming: Boolean,
    val foreground: Boolean,
    val interactive: Boolean,
    val externallyPowered: Boolean,
    val powerSaveMode: Boolean,
    val maxRefreshRateHz: Float,
)

/** The display and keep-awake requests that SideScreen is allowed to make. */
internal data class PowerPolicyDecision(
    val requestedRefreshRateHz: Float,
    val keepScreenOn: Boolean,
    val reason: String,
) {
    val requestsHighRefreshRate: Boolean
        get() = requestedRefreshRateHz >= PowerPolicy.HIGH_REFRESH_RATE_HZ
}

/**
 * Keeps SideScreen responsive without changing the power policy of Android's
 * other apps. Battery Saver is deliberately not disabled here: when the
 * tablet is externally powered, the video surface can still request 120 Hz;
 * on battery, an active stream is limited to a 60 Hz request.
 */
internal object PowerPolicy {
    const val HIGH_REFRESH_RATE_HZ = 120f
    const val BATTERY_REFRESH_RATE_HZ = 60f

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
}
