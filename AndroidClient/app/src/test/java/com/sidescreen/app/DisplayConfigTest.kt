package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisplayConfigTest {
    @Test
    fun parsesRotationAndFlipFlags() {
        assertEquals(
            DisplayConfig(2560, 1600, 90, flipHorizontal = true, flipVertical = true),
            DisplayConfig.fromWire(2560, 1600, 3090),
        )
    }

    @Test
    fun acceptsUpTo8kFrameAreaAndRejectsExcessiveAllocationRequests() {
        assertEquals(
            DisplayConfig(7680, 4320, 0, false, false),
            DisplayConfig.fromWire(7680, 4320, 0),
        )
        assertNull(DisplayConfig.fromWire(8192, 4320, 0))
        assertNull(DisplayConfig.fromWire(16_385, 100, 0))
    }

    @Test
    fun rejectsInvalidDimensionsAndTransforms() {
        listOf(
            Triple(0, 1200, 0),
            Triple(-1, 1200, 0),
            Triple(1920, 0, 0),
            Triple(1920, 1200, 45),
            Triple(1920, 1200, -90),
            Triple(1920, 1200, 4090),
        ).forEach { (width, height, transform) ->
            assertNull(DisplayConfig.fromWire(width, height, transform))
        }
    }
}
