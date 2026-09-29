package com.sidescreen.app

/**
 * Normalises a raw MotionEvent coordinate into the 0..1 space the Mac expects.
 *
 * Shared by the touch and stylus paths so all three agree on the degenerate
 * cases:
 *
 *  - A SurfaceView reports width/height 0 before its first layout, and
 *    0/0 is NaN. Kotlin's coerceIn returns NaN unchanged (both comparisons
 *    are false for NaN), so a clamp cannot repair it — the divisor has to be
 *    guarded.
 *  - StylusProtocol.encodeInto already applies finiteOr(0f) before clamping;
 *    the touch path has no host-side finiteness check, so the value must be
 *    finite before it reaches the wire.
 */
internal object PointerCoordinates {
    fun isUsable(
        width: Int,
        height: Int,
    ): Boolean = width > 0 && height > 0

    fun normalize(
        value: Float,
        extent: Int,
    ): Float = normalize(value, extent, flip = false)

    fun normalize(
        value: Float,
        extent: Int,
        flip: Boolean,
    ): Float {
        // An unmeasured surface has no meaningful coordinate; a flip must not
        // turn that placeholder into the far edge of the display.
        if (extent <= 0) return 0f
        val bounded = (value.finiteOr(0f) / extent.toFloat()).finiteOr(0f).coerceIn(0f, 1f)
        return if (flip) 1f - bounded else bounded
    }
}

internal fun Float.finiteOr(fallback: Float): Float = if (isFinite()) this else fallback
