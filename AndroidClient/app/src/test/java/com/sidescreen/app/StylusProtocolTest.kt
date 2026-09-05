package com.sidescreen.app

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StylusProtocolTest {
    @Test
    fun encodesFixedLittleEndianEvent() {
        val bytes =
            StylusProtocol.encode(
                StylusInputEvent(
                    x = 0.25f,
                    y = 0.75f,
                    action = StylusProtocol.ACTION_MOVE,
                    toolType = 2,
                    pressure = 0.6f,
                    tilt = 0.4f,
                    orientation = -0.2f,
                    buttonState = 64,
                ),
            )

        assertEquals(StylusProtocol.EVENT_SIZE, bytes.size)
        assertEquals(StylusProtocol.STYLUS_EVENT.toByte(), bytes[0])
        assertEquals(StylusProtocol.ACTION_MOVE.toByte(), bytes[1])
        assertEquals(2.toByte(), bytes[2])

        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buffer.position(4)
        assertEquals(0.25f, buffer.float, 0.0001f)
        assertEquals(0.75f, buffer.float, 0.0001f)
        assertEquals(0.6f, buffer.float, 0.0001f)
        assertEquals(0.4f, buffer.float, 0.0001f)
        assertEquals(-0.2f, buffer.float, 0.0001f)
        assertEquals(64, buffer.int)
    }

    @Test
    fun reusableEncoderMatchesAllocatingEncoder() {
        val event =
            StylusInputEvent(
                x = 0.1f,
                y = 0.9f,
                action = StylusProtocol.ACTION_MOVE,
                toolType = 2,
                pressure = 0.7f,
                tilt = 0.3f,
                orientation = 0.2f,
                buttonState = 64,
            )
        val expected = StylusProtocol.encode(event)
        val scratch = ByteArray(StylusProtocol.EVENT_SIZE + 8) { 0x55.toByte() }

        val written = StylusProtocol.encodeInto(event, scratch, offset = 4)

        assertEquals(StylusProtocol.EVENT_SIZE, written)
        assertArrayEquals(expected, scratch.copyOfRange(4, 4 + written))
        assertEquals(0x55.toByte(), scratch[0])
        assertEquals(0x55.toByte(), scratch.last())
    }

    @Test
    fun clampsUnsafeCoordinatesAndPressure() {
        val bytes =
            StylusProtocol.encode(
                StylusInputEvent(
                    x = 2f,
                    y = -1f,
                    action = 99,
                    toolType = 999,
                    pressure = Float.NaN,
                    tilt = Float.POSITIVE_INFINITY,
                    orientation = Float.NEGATIVE_INFINITY,
                    buttonState = 0,
                ),
            )

        assertEquals(StylusProtocol.ACTION_HOVER.toByte(), bytes[1])
        assertEquals(255.toByte(), bytes[2])
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buffer.position(4)
        assertEquals(1f, buffer.float, 0f)
        assertEquals(0f, buffer.float, 0f)
        assertEquals(0f, buffer.float, 0f)
        assertEquals(0f, buffer.float, 0f)
        assertEquals(0f, buffer.float, 0f)
        assertTrue(bytes.isNotEmpty())
    }
}
