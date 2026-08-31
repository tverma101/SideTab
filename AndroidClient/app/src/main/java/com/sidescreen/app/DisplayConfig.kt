package com.sidescreen.app

/**
 * Wire-level display configuration after decoding the Mac's transform field.
 * Stream pixels belong to the decoder; this metadata must never be allowed to
 * make the Android window negative, unbounded, or ambiguously rotated.
 */
internal data class DisplayConfig(
    val width: Int,
    val height: Int,
    val rotation: Int,
    val flipHorizontal: Boolean,
    val flipVertical: Boolean,
)

internal object DisplayConfigValidator {
    const val MIN_DIMENSION = 64
    const val MAX_DIMENSION = 16_384

    fun decode(width: Int, height: Int, transform: Int): DisplayConfig? {
        if (width !in MIN_DIMENSION..MAX_DIMENSION || height !in MIN_DIMENSION..MAX_DIMENSION) {
            return null
        }
        if (transform < 0) return null

        val rotation = transform % 1_000
        val flags = transform / 1_000
        if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) return null
        if (flags and 0x3.inv() != 0) return null

        return DisplayConfig(
            width = width,
            height = height,
            rotation = rotation,
            flipHorizontal = flags and 1 == 1,
            flipVertical = flags and 2 == 2,
        )
    }
}
