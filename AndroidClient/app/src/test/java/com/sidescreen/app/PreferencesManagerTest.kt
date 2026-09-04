package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class PreferencesManagerTest {
    @Test
    fun edgeThresholdDefaultSnapsToSliderStep() {
        assertEquals(0.03f, snapToStep(8.0f / 255.0f, 0.0f, 0.1f, 0.005f), 0.0f)
    }

    @Test
    fun sliderValuesAreClampedAndSnapped() {
        assertEquals(0.2f, snapToStep(-1.0f, 0.2f, 1.0f, 0.05f), 0.0f)
        assertEquals(1.0f, snapToStep(2.0f, 0.2f, 1.0f, 0.05f), 0.0f)
        assertEquals(0.75f, snapToStep(0.73f, 0.0f, 1.0f, 0.05f), 0.0f)
    }
}
