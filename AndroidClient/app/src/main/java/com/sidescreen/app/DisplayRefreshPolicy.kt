package com.sidescreen.app

import kotlin.math.abs

/**
 * Pure refresh-rate helpers so odd panel mode tables can be tested without
 * Android hardware. [PowerPolicy] decides *which* rate SideTab asks for; this
 * only maps that request onto what a given panel can accept.
 */
internal object DisplayRefreshPolicy {
    /** The highest rate the host streams at, and the decoder's provisioning target. */
    const val STREAM_INTENT_HZ = 120f

    /**
     * Before API 34, WindowManager.LayoutParams.preferredRefreshRate must equal
     * an advertised refresh rate (Android 14+ accepts any intended rate).
     * Choose the same-resolution mode closest to the intended rate. On an
     * equal-distance tie prefer the higher rate so presentation is not
     * unnecessarily capped below the stream rate.
     *
     * Examples:
     *   60/90/120/144 -> 120
     *   60/90/144     -> 144 (24 away vs 30 for 90)
     *   60/96/144     -> 144 (tie at 24; prefer higher)
     *
     * Invalid/non-finite values are ignored. If no usable advertised rate is
     * present, preserve the current display rate.
     */
    fun chooseLegacyPreferredRate(
        sameResolutionRates: Iterable<Float>,
        currentRate: Float,
        intendedRate: Float = STREAM_INTENT_HZ,
    ): Float {
        val fallback = if (currentRate.isFinite() && currentRate > 0f) currentRate else 60f
        if (!intendedRate.isFinite() || intendedRate <= 0f) return fallback

        return sameResolutionRates
            .asSequence()
            .filter { it.isFinite() && it > 0f }
            .minWithOrNull(
                compareBy<Float> { abs(it - intendedRate) }
                    .thenByDescending { it },
            )
            ?: fallback
    }
}
