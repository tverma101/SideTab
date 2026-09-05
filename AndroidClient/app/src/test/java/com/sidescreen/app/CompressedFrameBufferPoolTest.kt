package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

class CompressedFrameBufferPoolTest {
    @Test
    fun reusesReturnedBufferWhenLargeEnough() {
        val pool = CompressedFrameBufferPool()
        val first = pool.acquire(64 * 1024)
        pool.release(first)

        val second = pool.acquire(32 * 1024)
        assertSame(first, second)
    }

    @Test
    fun growsOnceAndThenReusesLargestBuffer() {
        val pool = CompressedFrameBufferPool()
        val small = pool.acquire(32 * 1024)
        pool.release(small)

        val large = pool.acquire(256 * 1024)
        assertNotSame(small, large)
        pool.release(large)
        assertEquals(256 * 1024, pool.retainedSizeForTest())

        val nextSmall = pool.acquire(16 * 1024)
        assertSame(large, nextSmall)
    }

    @Test
    fun smallerLateReturnCannotEvictLargerRetainedBuffer() {
        val pool = CompressedFrameBufferPool()
        val large = ByteArray(512 * 1024)
        val small = ByteArray(64 * 1024)

        pool.release(large)
        pool.release(small)

        assertEquals(512 * 1024, pool.retainedSizeForTest())
        assertSame(large, pool.acquire(128 * 1024))
    }
}
