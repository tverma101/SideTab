package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairedHostEntryTest {
    private val token = ByteArray(32) { it.toByte() }

    @Test
    fun defaultControlPortFollowsVideoPort() {
        val entry = PairedHostStorage.Entry("192.168.1.4", 54321, token, "Mac")
        assertEquals(54322, entry.effectiveControlPort())
    }

    @Test
    fun explicitControlPortOverridesDerivedPort() {
        val entry =
            PairedHostStorage.Entry(
                host = "192.168.1.4",
                port = 54321,
                token = token,
                macName = "Mac",
                controlPortOverride = 55123,
            )
        assertEquals(55123, entry.effectiveControlPort())
    }

    @Test
    fun derivedControlPortRejectsVideoPortAtMaximum() {
        val entry = PairedHostStorage.Entry("192.168.1.4", 65535, token, "Mac")
        assertNull(entry.effectiveControlPort())
    }

    @Test
    fun explicitControlPortStillWorksAtMaximumVideoPort() {
        val entry =
            PairedHostStorage.Entry(
                host = "192.168.1.4",
                port = 65535,
                token = token,
                macName = "Mac",
                controlPortOverride = 55000,
            )
        assertEquals(55000, entry.effectiveControlPort())
    }
}
