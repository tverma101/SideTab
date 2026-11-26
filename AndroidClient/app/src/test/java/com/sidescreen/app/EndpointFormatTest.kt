package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class EndpointFormatTest {
    @Test
    fun ipv4KeepsPlainNotation() {
        assertEquals("192.168.1.32:5555", EndpointFormat.of("192.168.1.32", 5555))
    }

    @Test
    fun hostnameKeepsPlainNotation() {
        assertEquals("mac.local:54321", EndpointFormat.of("mac.local", 54321))
    }

    @Test
    fun ipv6LiteralGetsBracketed() {
        assertEquals(
            "[2603:6081:e200:162:1099:130f:9333:17e7]:54321",
            EndpointFormat.of("2603:6081:e200:162:1099:130f:9333:17e7", 54321),
        )
    }

    @Test
    fun compressedIpv6LiteralGetsBracketed() {
        assertEquals("[::1]:5555", EndpointFormat.of("::1", 5555))
    }

    @Test
    fun zoneScopedIpv6LiteralGetsBracketed() {
        assertEquals("[fe80::1%en0]:5555", EndpointFormat.of("fe80::1%en0", 5555))
    }

    @Test
    fun alreadyBracketedLiteralIsNotDoubleWrapped() {
        assertEquals("[::1]:5555", EndpointFormat.of("[::1]", 5555))
    }

    @Test
    fun surroundingWhitespaceIsTrimmed() {
        assertEquals("mac.local:54321", EndpointFormat.of(" mac.local ", 54321))
    }
}
