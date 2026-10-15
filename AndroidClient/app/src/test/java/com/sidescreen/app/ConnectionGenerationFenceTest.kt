package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class ConnectionGenerationFenceTest {
    @Test
    fun retirementWaitsForAnInFlightOwnedSideEffectAndRejectsLaterCallbacks() {
        val fence = ConnectionGenerationFence()
        val oldGeneration = fence.advance()
        val callbackEntered = CountDownLatch(1)
        val finishCallback = CountDownLatch(1)
        val advanceStarted = CountDownLatch(1)
        val retirementThread = AtomicReference<Thread>()
        val order = mutableListOf<String>()
        val executor = Executors.newFixedThreadPool(2)

        try {
            val callback = executor.submit<Boolean> {
                fence.runIfCurrent(oldGeneration) {
                    callbackEntered.countDown()
                    check(finishCallback.await(5, TimeUnit.SECONDS))
                    order += "callback"
                }
            }
            assertTrue(callbackEntered.await(5, TimeUnit.SECONDS))

            val retirement = executor.submit<Long> {
                retirementThread.set(Thread.currentThread())
                advanceStarted.countDown()
                fence.advance()
            }
            assertTrue(advanceStarted.await(5, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (retirementThread.get()?.state != Thread.State.BLOCKED && System.nanoTime() < deadline) {
                Thread.yield()
            }
            assertEquals(
                "retirement must contend on the callback fence",
                Thread.State.BLOCKED,
                retirementThread.get()?.state,
            )
            finishCallback.countDown()

            val newGeneration = retirement.get(5, TimeUnit.SECONDS)
            assertTrue(callback.get(5, TimeUnit.SECONDS))
            assertEquals(listOf("callback"), order)
            assertFalse(fence.runIfCurrent(oldGeneration) { order += "stale callback" })
            assertTrue(fence.runIfCurrent(newGeneration) { order += "new callback" })
            assertEquals(listOf("callback", "new callback"), order)
        } finally {
            finishCallback.countDown()
            executor.shutdownNow()
        }
    }
}
