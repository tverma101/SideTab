package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameTimingWindowTest {
    @Test
    fun uniformCadenceReportsExpectedFpsWithoutVariance() {
        val window = FrameTimingWindow(capacity = 6, minSamples = 4, emitEvery = 4)

        assertFalse(window.add(0L))
        assertFalse(window.add(10_000_000L))
        assertFalse(window.add(20_000_000L))
        assertTrue(window.add(30_000_000L))

        assertEquals(100.0, window.fps, 0.00001)
        assertEquals(0.0, window.stdDevMs, 0.00001)
    }

    @Test
    fun irregularCadenceReportsPopulationStdDev() {
        val window = FrameTimingWindow(capacity = 4, minSamples = 4, emitEvery = 4)

        window.add(0L)
        window.add(10_000_000L)
        window.add(30_000_000L)
        assertTrue(window.add(40_000_000L))

        assertEquals(75.0, window.fps, 0.00001)
        assertEquals(4.714045, window.stdDevMs, 0.00001)
    }

    @Test
    fun ringWrapUsesNewestWindowInChronologicalOrder() {
        val window = FrameTimingWindow(capacity = 4, minSamples = 4, emitEvery = 2)

        window.add(0L)
        window.add(10_000_000L)
        window.add(20_000_000L)
        assertTrue(window.add(30_000_000L))
        assertFalse(window.add(40_000_000L))
        assertTrue(window.add(50_000_000L))

        assertEquals(100.0, window.fps, 0.00001)
        assertEquals(0.0, window.stdDevMs, 0.00001)
    }

    @Test
    fun nonIncreasingTimestampIsIgnoredRatherThanCorruptingStats() {
        val window = FrameTimingWindow(capacity = 4, minSamples = 4, emitEvery = 4)

        window.add(10_000_000L)
        window.add(20_000_000L)
        window.add(20_000_000L)
        assertTrue(window.add(30_000_000L))

        assertEquals(100.0, window.fps, 0.00001)
        assertEquals(0.0, window.stdDevMs, 0.00001)
    }

    @Test
    fun resetDropsOldCadence() {
        val window = FrameTimingWindow(capacity = 4, minSamples = 4, emitEvery = 4)
        window.add(0L)
        window.add(10_000_000L)
        window.add(20_000_000L)
        window.add(30_000_000L)

        window.reset()

        assertEquals(0.0, window.fps, 0.0)
        assertEquals(0.0, window.stdDevMs, 0.0)
        assertFalse(window.add(1_000_000_000L))
        assertFalse(window.add(1_010_000_000L))
        assertFalse(window.add(1_020_000_000L))
        assertTrue(window.add(1_030_000_000L))
        assertEquals(100.0, window.fps, 0.00001)
    }
}
