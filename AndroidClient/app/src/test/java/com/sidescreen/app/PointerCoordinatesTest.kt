package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PointerCoordinatesTest {
    @Test
    fun zeroSizedSurfaceYieldsZeroInsteadOfNaN() {
        // 0/0 is NaN, and coerceIn returns NaN unchanged: both comparisons are
        // false for NaN, so a clamp cannot repair the divisor.
        assertEquals(0f, PointerCoordinates.normalize(0f, extent = 0), 0f)
        assertEquals(0f, PointerCoordinates.normalize(37f, extent = 0), 0f)
        assertEquals(0f, PointerCoordinates.normalize(Float.NaN, extent = 0), 0f)
    }

    @Test
    fun nonFiniteCoordinatesNeverReachTheWire() {
        assertEquals(0f, PointerCoordinates.normalize(Float.NaN, extent = 1920), 0f)
        assertEquals(0f, PointerCoordinates.normalize(Float.POSITIVE_INFINITY, extent = 1920), 0f)
        assertEquals(0f, PointerCoordinates.normalize(Float.NEGATIVE_INFINITY, extent = 1920), 0f)
    }

    @Test
    fun normalisesAndClampsToTheUnitSquare() {
        assertEquals(0f, PointerCoordinates.normalize(-4f, extent = 1920), 0f)
        assertEquals(0.5f, PointerCoordinates.normalize(960f, extent = 1920), 1e-6f)
        assertEquals(1f, PointerCoordinates.normalize(4000f, extent = 1920), 0f)
    }

    @Test
    fun flipMirrorsInsideTheUnitSquare() {
        assertEquals(0.25f, PointerCoordinates.normalize(1440f, 1920, flip = true), 1e-6f)
        assertEquals(0f, PointerCoordinates.normalize(1920f, 1920, flip = true), 0f)
        assertEquals(0f, PointerCoordinates.normalize(Float.NaN, 0, flip = true), 0f)
    }

    @Test
    fun onlyMeasuredSurfacesAreUsable() {
        assertFalse(PointerCoordinates.isUsable(0, 1080))
        assertFalse(PointerCoordinates.isUsable(1920, 0))
        assertFalse(PointerCoordinates.isUsable(0, 0))
        assertFalse(PointerCoordinates.isUsable(-1, 1080))
        assertTrue(PointerCoordinates.isUsable(1920, 1200))
    }
}
