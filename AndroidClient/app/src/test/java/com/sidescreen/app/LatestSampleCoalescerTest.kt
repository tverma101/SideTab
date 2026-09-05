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
        val epoch = slot.offer(1)
        assertTrue(epoch != null)
        assertNull(slot.offer(2))
        assertNull(slot.offer(3))
        assertEquals(3, slot.takeLatest(epoch!!))
        assertFalse(slot.finishBurst(epoch))
    }

    @Test
    fun pendingArrivalDuringBurstRequestsContinuation() {
        val slot = LatestSampleCoalescer<Int>()
        val epoch = slot.offer(1)!!
        assertEquals(1, slot.takeLatest(epoch))
        assertNull(slot.offer(2))
        assertTrue(slot.finishBurst(epoch))
        assertEquals(2, slot.takeLatest(epoch))
        assertFalse(slot.finishBurst(epoch))
    }

    @Test
    fun boundaryPreventsOldDrainFromConsumingNewMotion() {
        val slot = LatestSampleCoalescer<Int>()
        val oldEpoch = slot.offer(9)!!

        slot.advanceBoundary()
        val newEpoch = slot.offer(10)!!

        assertNull(slot.takeLatest(oldEpoch))
        assertFalse(slot.finishBurst(oldEpoch))
        assertEquals(10, slot.takeLatest(newEpoch))
        assertFalse(slot.finishBurst(newEpoch))
    }

    @Test
    fun boundaryDropsObsoletePendingMotion() {
        val slot = LatestSampleCoalescer<Int>()
        val oldEpoch = slot.offer(9)!!
        slot.advanceBoundary()
        assertNull(slot.takeLatest(oldEpoch))
        assertFalse(slot.finishBurst(oldEpoch))

        val snapshot = slot.snapshotForTest()
        assertEquals(1L, snapshot.first)
        assertNull(snapshot.third)
    }
}
