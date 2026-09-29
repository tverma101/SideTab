package com.sidescreen.app

/** Validated display metadata received from the Mac before allocating a decoder. */
internal data class DisplayConfig(
    val width: Int,
    val height: Int,
    val rotation: Int,
    val flipHorizontal: Boolean,
    val flipVertical: Boolean,
) {
    companion object {
        private const val MAX_DIMENSION = 16_384
        private const val MAX_PIXELS = 33_554_432L // 8K UHD
        private val VALID_ROTATIONS = setOf(0, 90, 180, 270)

        fun fromWire(width: Int, height: Int, transform: Int): DisplayConfig? {
            if (width !in 1..MAX_DIMENSION || height !in 1..MAX_DIMENSION) return null
            if (width.toLong() * height.toLong() > MAX_PIXELS) return null

            val rotation = transform % 1000
            val flags = transform / 1000
            if (rotation !in VALID_ROTATIONS || flags !in 0..3) return null

            return DisplayConfig(
                width = width,
                height = height,
                rotation = rotation,
                flipHorizontal = flags and 1 == 1,
                flipVertical = flags and 2 == 2,
            )
        }
    }
}
