package com.sidescreen.app

import kotlin.math.abs

/** Pure refresh-rate policy so odd panel mode tables can be tested without Android hardware. */
internal object DisplayRefreshPolicy {
    const val STREAM_INTENT_HZ = 120f

    /**
     * Android 14+ accepts the app's intended frame rate even when it is not an
     * exact advertised display mode. Tell the scheduler SideScreen intends to
     * produce up to 120 FPS and let Android choose the compatible panel mode.
     */
    fun modernPreferredRate(): Float = STREAM_INTENT_HZ

    /**
     * Before API 34, WindowManager.LayoutParams.preferredRefreshRate must equal
     * an advertised refresh rate. Choose the same-resolution mode closest to
     * SideScreen's 120-FPS intent. On an equal-distance tie prefer the higher
     * rate so presentation is not unnecessarily capped below the stream rate.
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
