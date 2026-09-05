package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LatestSampleCoalescerTest {
    @Test
    fun overwritesPendingMotionWithoutSchedulingAnotherDrain() {
        val slot = LatestSampleCoalescer<Int>()
        assertTrue(slot.offer(1))
        assertFalse(slot.offer(2))
        assertFalse(slot.offer(3))
        assertEquals(3, slot.takeLatest())
        assertFalse(slot.finishBurst())
    }

    @Test
    fun pendingArrivalDuringBurstRequestsContinuation() {
        val slot = LatestSampleCoalescer<Int>()
        assertTrue(slot.offer(1))
        assertEquals(1, slot.takeLatest())
        assertFalse(slot.offer(2))
        assertTrue(slot.finishBurst())
        assertEquals(2, slot.takeLatest())
        assertFalse(slot.finishBurst())
    }

    @Test
    fun boundaryEventCanDiscardObsoleteMotion() {
        val slot = LatestSampleCoalescer<Int>()
        assertTrue(slot.offer(9))
        slot.clearPending()
        assertNull(slot.takeLatest())
        assertFalse(slot.finishBurst())

        // Latch was released, so the next gesture can schedule a new drain.
        assertTrue(slot.offer(10))
    }
}
