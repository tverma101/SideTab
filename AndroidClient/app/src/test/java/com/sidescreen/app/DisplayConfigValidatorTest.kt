package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayConfigValidatorTest {
    @Test
    fun acceptsValidDimensionsRotationAndFlipBits() {
        val config = DisplayConfigValidator.decode(2_800, 1_752, 90 + 1_000 + 2_000)

        assertEquals(2_800, config?.width)
        assertEquals(1_752, config?.height)
        assertEquals(90, config?.rotation)
        assertTrue(config?.flipHorizontal == true)
        assertTrue(config?.flipVertical == true)
    }

    @Test
    fun rejectsInvalidDimensionsRotationsAndFlags() {
        assertNull(DisplayConfigValidator.decode(0, 1_752, 0))
        assertNull(DisplayConfigValidator.decode(16_385, 1_752, 0))
        assertNull(DisplayConfigValidator.decode(2_800, 1_752, 45))
        assertNull(DisplayConfigValidator.decode(2_800, 1_752, 4_000))
        assertNull(DisplayConfigValidator.decode(2_800, 1_752, -1))
    }

    @Test
    fun validTransformCanHaveNoFlips() {
        val config = DisplayConfigValidator.decode(1920, 1080, 180)

        assertFalse(config?.flipHorizontal == true)
        assertFalse(config?.flipVertical == true)
    }
}
