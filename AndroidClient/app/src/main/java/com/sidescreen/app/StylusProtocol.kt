package com.sidescreen.app

import java.nio.ByteBuffer
import java.nio.ByteOrder

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

    fun encode(event: StylusInputEvent): ByteArray {
        val buffer = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(STYLUS_EVENT.toByte())
        buffer.put(event.action.coerceIn(ACTION_DOWN, ACTION_HOVER).toByte())
        buffer.put(event.toolType.coerceIn(0, 0xFF).toByte())
        buffer.put(0) // reserved for a future protocol flag byte
        buffer.putFloat(event.x.finiteOr(0f).coerceIn(0f, 1f))
        buffer.putFloat(event.y.finiteOr(0f).coerceIn(0f, 1f))
        buffer.putFloat(event.pressure.finiteOr(0f).coerceIn(0f, 1f))
        buffer.putFloat(event.tilt.finiteOr(0f))
        buffer.putFloat(event.orientation.finiteOr(0f))
        buffer.putInt(event.buttonState)
        return buffer.array()
    }

    private fun Float.finiteOr(fallback: Float): Float = if (isFinite()) this else fallback
}
