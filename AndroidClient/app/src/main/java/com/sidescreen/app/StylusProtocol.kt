package com.sidescreen.app

/**
 * Android-to-Mac stylus protocol.
 *
 * Stylus support is negotiated on the video connection so an older Mac host
 * never receives an extended event it cannot parse. The event itself can then
 * use the dedicated control socket, with the video socket as a fallback.
 *
 * Wire format (little-endian, fixed 28 bytes):
 *   [14 type][action 1][tool type 1][reserved 1]
 *   [x f32][y f32][pressure f32][tilt f32][orientation f32][buttons u32]
 */
data class StylusInputEvent(
    val x: Float,
    val y: Float,
    val action: Int,
    val toolType: Int,
    val pressure: Float,
    val tilt: Float,
    val orientation: Float,
    val buttonState: Int,
)

object StylusProtocol {
    const val CLIENT_SUPPORTS_STYLUS: Int = 12
    const val SERVER_SUPPORTS_STYLUS: Int = 13
    const val STYLUS_EVENT: Int = 14

    const val ACTION_DOWN: Int = 0
    const val ACTION_MOVE: Int = 1
    const val ACTION_UP: Int = 2
    const val ACTION_HOVER: Int = 3

    const val EVENT_SIZE: Int = 28

    fun encode(event: StylusInputEvent): ByteArray =
        ByteArray(EVENT_SIZE).also { encodeInto(event, it) }

    /**
     * Encode directly into caller-owned storage. The 120 Hz S Pen path reuses
     * one scratch buffer under its send lock, and these scalar LE writes avoid
     * allocating a ByteBuffer wrapper for every packet.
     */
    fun encodeInto(
        event: StylusInputEvent,
        target: ByteArray,
        offset: Int = 0,
    ): Int {
        require(offset >= 0 && target.size - offset >= EVENT_SIZE) {
            "target must have at least $EVENT_SIZE writable bytes"
        }

        target[offset] = STYLUS_EVENT.toByte()
        target[offset + 1] = event.action.coerceIn(ACTION_DOWN, ACTION_HOVER).toByte()
        target[offset + 2] = event.toolType.coerceIn(0, 0xFF).toByte()
        target[offset + 3] = 0 // reserved for a future protocol flag byte
        putFloatLE(target, offset + 4, event.x.finiteOr(0f).coerceIn(0f, 1f))
        putFloatLE(target, offset + 8, event.y.finiteOr(0f).coerceIn(0f, 1f))
        putFloatLE(target, offset + 12, event.pressure.finiteOr(0f).coerceIn(0f, 1f))
        putFloatLE(target, offset + 16, event.tilt.finiteOr(0f))
        putFloatLE(target, offset + 20, event.orientation.finiteOr(0f))
        putIntLE(target, offset + 24, event.buttonState)
        return EVENT_SIZE
    }

    private fun putFloatLE(
        target: ByteArray,
        offset: Int,
        value: Float,
    ) = putIntLE(target, offset, value.toRawBits())

    private fun putIntLE(
        target: ByteArray,
        offset: Int,
        value: Int,
    ) {
        target[offset] = value.toByte()
        target[offset + 1] = (value ushr 8).toByte()
        target[offset + 2] = (value ushr 16).toByte()
        target[offset + 3] = (value ushr 24).toByte()
    }

    private fun Float.finiteOr(fallback: Float): Float = if (isFinite()) this else fallback
}
