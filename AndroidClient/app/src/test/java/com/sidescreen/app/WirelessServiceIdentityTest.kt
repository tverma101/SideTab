package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class WirelessServiceIdentityTest {
    @Test
    fun identityIsStableAndCrossPlatformCompatible() {
        val token = ByteArray(32) { index -> index.toByte() }
        assertEquals("SideScreen-630dcd2966c43366", WirelessServiceIdentity.nameForToken(token))
    }

    @Test
    fun serviceTypeUsesBonjourTcp() {
        assertEquals("_sidescreen._tcp.", WirelessServiceIdentity.SERVICE_TYPE)
    }
}
