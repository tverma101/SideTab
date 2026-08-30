package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionModeHandshakeTest {
    @Test
    fun helloRoundTripsBothModesWithMarkedPayload() {
        listOf(ConnectionMode.USB, ConnectionMode.WIRELESS).forEach { mode ->
            val message = ConnectionModeHandshake.encodeClientHello(mode)

            assertEquals(ConnectionModeHandshake.CLIENT_HELLO_TYPE, message[0].toInt())
            assertTrue(message[1].toInt() and 0x80 != 0)
            assertEquals(mode, ConnectionModeHandshake.decodeClientHello(message[0].toInt(), message[1].toInt() and 0xFF))
        }
    }

    @Test
    fun serverResultRoundTripsAcceptedAndRejectedResults() {
        val message = ConnectionModeHandshake.encodeServerResult(
            ConnectionModeHandshake.ResultCode.WRONG_MODE,
            ConnectionMode.WIRELESS,
        )

        val result = ConnectionModeHandshake.decodeServerResult(
            message[0].toInt(),
            message[1].toInt() and 0xFF,
            message[2].toInt() and 0xFF,
        )

        assertEquals(ConnectionModeHandshake.ResultCode.WRONG_MODE, result?.code)
        assertEquals(ConnectionMode.WIRELESS, result?.expectedMode)
        assertFalse(result?.accepted == true)
        assertTrue(ConnectionModeHandshake.failureMessage(result!!).contains("Wireless"))
    }

    @Test
    fun malformedOrUnmarkedMessagesAreRejected() {
        assertNull(ConnectionModeHandshake.decodeClientHello(15, 0x80))
        assertNull(ConnectionModeHandshake.decodeClientHello(16, 1))
        assertNull(ConnectionModeHandshake.decodeClientHello(16, 0x80 or 9))
        assertNull(ConnectionModeHandshake.decodeServerResult(17, 99, 0x80))
        assertNull(ConnectionModeHandshake.decodeServerResult(17, 0, 1))
    }
}
