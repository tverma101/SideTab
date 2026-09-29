package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class UsbConnectionTargetTest {
    @Test
    fun emptyFieldsUseLoopbackDefaults() {
        assertEquals(
            UsbConnectionTarget.ParseResult.Valid(UsbConnectionTarget("127.0.0.1", 54321)),
            UsbConnectionTarget.parse("", ""),
        )
    }

    @Test
    fun trimsHostAndPortAndNormalizesLocalhost() {
        assertEquals(
            UsbConnectionTarget.ParseResult.Valid(UsbConnectionTarget("127.0.0.1", 54322)),
            UsbConnectionTarget.parse(" localhost ", " 54322 "),
        )
    }

    @Test
    fun acceptsIpv6LoopbackAndPortBoundaries() {
        assertEquals(
            UsbConnectionTarget.ParseResult.Valid(UsbConnectionTarget("::1", 1)),
            UsbConnectionTarget.parse("::1", "1"),
        )
        assertEquals(
            UsbConnectionTarget.ParseResult.Valid(UsbConnectionTarget("example.local", 65534)),
            UsbConnectionTarget.parse("example.local", "65534"),
        )
    }

    @Test
    fun rejectsMalformedHostsAndPortsInsteadOfSilentlyUsingDefaults() {
        listOf("bad host", "   ").forEach { host ->
            assertSame(UsbConnectionTarget.ParseResult.InvalidHost, UsbConnectionTarget.parse(host, "54321"))
        }
        listOf("abc", "0", "65535", "65536", "-1", "+54321", "999999999999").forEach { port ->
            assertSame(UsbConnectionTarget.ParseResult.InvalidPort, UsbConnectionTarget.parse("", port))
        }
    }
}
