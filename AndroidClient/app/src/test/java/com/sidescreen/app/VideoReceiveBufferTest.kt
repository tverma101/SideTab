package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

class VideoReceiveBufferTest {
    @Test
    fun varyingFrameSizesReuseStorageWithinItsCapacity() {
        val buffer = VideoReceiveBuffer()
        val first = buffer.acquire(40_000)
        assertSame(first, buffer.acquire(48_000))

        val grown = buffer.acquire(100_000)
        assertNotSame(first, grown)
        assertSame(grown, buffer.acquire(120_000))
        assertSame(grown, buffer.acquire(1))
    }

    @Test
    fun largeFramesAndNewConnectionsDoNotRetainPriorStorage() {
        val buffer = VideoReceiveBuffer()
        val retained = buffer.acquire(1024 * 1024)
        val largeFrameSize = 5 * 1024 * 1024
        val large = buffer.acquire(largeFrameSize)
        assertEquals(largeFrameSize, large.size)
        assertNotSame(large, buffer.acquire(largeFrameSize))
        assertSame(retained, buffer.acquire(16_000))
        assertNotSame(retained, VideoReceiveBuffer().acquire(16_000))
    }
}
