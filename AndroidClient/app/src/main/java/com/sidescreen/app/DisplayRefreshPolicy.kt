package com.sidescreen.app

/** Pure refresh-rate policy so odd panel mode tables can be tested without Android hardware. */
internal object DisplayRefreshPolicy {
    const val MAX_STREAM_REFRESH_HZ = 120f
    private const val RATE_EPSILON_HZ = 0.5f

    /**
     * Pick the highest advertised same-resolution refresh rate no higher than
     * SideScreen's stream ceiling. Pre-API-34 WindowManager requires an exact
     * advertised refresh rate, so this deliberately does not synthesize 120.
     *
     * Invalid/non-finite values are ignored. If the panel exposes no usable
     * candidate at or below the ceiling, preserve the current mode.
     */
    fun choosePreferredRate(
        sameResolutionRates: Iterable<Float>,
        currentRate: Float,
        maxStreamRate: Float = MAX_STREAM_REFRESH_HZ,
    ): Float {
        if (!currentRate.isFinite() || currentRate <= 0f) return 60f
        if (!maxStreamRate.isFinite() || maxStreamRate <= 0f) return currentRate

        return sameResolutionRates
            .asSequence()
            .filter { it.isFinite() && it > 0f }
            .filter { it <= maxStreamRate + RATE_EPSILON_HZ }
            .maxOrNull()
            ?: currentRate
    }
}
