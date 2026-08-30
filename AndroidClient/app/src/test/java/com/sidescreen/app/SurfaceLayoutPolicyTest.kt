package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceLayoutPolicyTest {
    @Test
    fun validStreamAndPanelUseMatchConstraints() {
        val decision = SurfaceLayoutPolicy.decide(1920, 1080, 2560, 1600)

        assertEquals(0, decision.width)
        assertEquals(0, decision.height)
        assertTrue(decision.geometryKnown)
    }

    @Test
    fun invalidOrNotYetMeasuredGeometryStillKeepsSurfaceFillingPanel() {
        val decision = SurfaceLayoutPolicy.decide(0, 0, 0, 0)

        assertEquals(0, decision.width)
        assertEquals(0, decision.height)
        assertFalse(decision.geometryKnown)
    }
}
