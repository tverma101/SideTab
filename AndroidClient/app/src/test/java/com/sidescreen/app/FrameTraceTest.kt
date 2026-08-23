package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class FrameTraceTest {
    @Test
    fun visibleLatencyWindowReportsPercentiles() {
        val stats = FrameTraceStats(maxSamples = 4)
        for (i in 1L..4L) {
            stats.add(
                FrameTrace(
                    frameId = i,
                    hostCaptureNs = i,
                    captureNs = 1_000_000_000L,
                    receivedNs = 1_000_000_000L,
                    renderedNs = 1_000_000_000L + i * 1_000_000L,
                ),
            )
        }

        val summary = stats.summary()
        assertNotNull(summary)
        assertEquals(4, summary?.count)
        assertEquals(2.0, summary?.p50Ms ?: 0.0, 0.001)
        assertEquals(4.0, summary?.p99Ms ?: 0.0, 0.001)
        assertEquals(4.0, summary?.maxMs ?: 0.0, 0.001)
    }
}
