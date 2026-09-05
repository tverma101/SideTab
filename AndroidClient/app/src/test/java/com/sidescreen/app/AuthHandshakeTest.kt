package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AuthHandshakeTest {
    @Test
    fun encodesGoldenBytes() {
        val token = ByteArray(32) { it.toByte() }
        val bytes = AuthHandshake.encodeRequest(token, "iPad Air")
        val expected =
            byteArrayOf(0x53, 0x53, 0x57, 0x41) +
                ByteArray(32) { it.toByte() } +
                byteArrayOf(8) +
                "iPad Air".toByteArray()
        assertArrayEquals(expected, bytes)
    }

    @Test
    fun truncatesAsciiNameTo64Bytes() {
        val bytes = AuthHandshake.encodeRequest(ByteArray(32), "x".repeat(65))
        val nameLength = bytes[36].toInt() and 0xff

        assertEquals(64, nameLength)
        assertEquals("x".repeat(64), bytes.copyOfRange(37, 37 + nameLength).toString(Charsets.UTF_8))
    }

    @Test
    fun truncatesUnicodeOnCodePointBoundary() {
        val bytes = AuthHandshake.encodeRequest(ByteArray(32), "😀".repeat(20))
        val nameLength = bytes[36].toInt() and 0xff
        val decoded = bytes.copyOfRange(37, 37 + nameLength).toString(Charsets.UTF_8)

        assertEquals(64, nameLength)
        assertEquals("😀".repeat(16), decoded)
    }

    @Test
    fun blankDeviceNameFallsBackToAndroid() {
        val bytes = AuthHandshake.encodeRequest(ByteArray(32), "   ")
        val nameLength = bytes[36].toInt() and 0xff

        assertEquals("Android", bytes.copyOfRange(37, 37 + nameLength).toString(Charsets.UTF_8))
    }

    @Test
    fun rejectsTokenWrongSize() {
        try {
            AuthHandshake.encodeRequest(ByteArray(31), "x")
            error("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            // OK
        }
    }

    @Test
    fun parseOKResponse() {
        val r = AuthHandshake.parseResponse(byteArrayOf(0x53, 0x53, 0x57, 0x52, 0x00))
        assertEquals(AuthHandshake.ResponseStatus.OK, r)
    }

    @Test
    fun parseInvalidTokenResponse() {
        val r = AuthHandshake.parseResponse(byteArrayOf(0x53, 0x53, 0x57, 0x52, 0x01))
        assertEquals(AuthHandshake.ResponseStatus.INVALID_TOKEN, r)
    }

    @Test
    fun parseInvalidMagicResponseReturnsNull() {
        val r = AuthHandshake.parseResponse(byteArrayOf(0x58, 0x58, 0x58, 0x58, 0x00))
        assertNull(r)
    }
}
