package com.sidescreen.app

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BlockingSingleSlotTest {
    @Test
    fun producerAndConsumerCanTransferManyValuesWithoutLosingOrder() {
        val slot = BlockingSingleSlot<Int>()
        val open = AtomicBoolean(true)
        val count = 50_000
        val executor = Executors.newFixedThreadPool(2)

        try {
            val consumer = executor.submit {
                repeat(count) { expected ->
                    assertEquals(expected, slot.take { open.get() })
                }
            }
            val producer = executor.submit {
                repeat(count) { value ->
                    assertTrue(slot.publish(value) { open.get() })
                }
            }
            producer.get(10, TimeUnit.SECONDS)
            consumer.get(10, TimeUnit.SECONDS)
        } finally {
            open.set(false)
            slot.close { error("all values should have been consumed") }
            executor.shutdownNow()
        }
    }

    @Test
    fun closingSlotUnblocksProducerAndDiscardsQueuedValueExactlyOnce() {
        val slot = BlockingSingleSlot<Int>()
        val open = AtomicBoolean(true)
        val entered = CountDownLatch(1)
        val discarded = AtomicInteger()
        val producerThread = AtomicReference<Thread>()
        assertTrue(slot.publish(1) { open.get() })

        val producer = Thread {
            producerThread.set(Thread.currentThread())
            entered.countDown()
            assertFalse(slot.publish(2) { open.get() })
        }
        producer.start()
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        awaitWaiting(producerThread.get())
        open.set(false)
        slot.close { value ->
            assertEquals(1, value)
            discarded.incrementAndGet()
        }
        producer.join(TimeUnit.SECONDS.toMillis(1))

        assertFalse("producer remained blocked after close", producer.isAlive)
        assertEquals(1, discarded.get())
        assertFalse("closed slot accepted a later value", slot.publish(3) { true })
        assertEquals(null, slot.take { true })
        slot.close { error("close must discard at most once") }
    }

    @Test
    fun closingSlotUnblocksConsumer() {
        val slot = BlockingSingleSlot<Int>()
        val entered = CountDownLatch(1)
        val consumerThread = AtomicReference<Thread>()
        val result = AtomicReference<Int?>()
        val consumer = Thread {
            consumerThread.set(Thread.currentThread())
            entered.countDown()
            result.set(slot.take { true })
        }
        consumer.start()
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        awaitWaiting(consumerThread.get())
        slot.close { error("empty slot has nothing to discard") }
        consumer.join(TimeUnit.SECONDS.toMillis(1))
        assertFalse("consumer remained blocked after close", consumer.isAlive)
        assertEquals(null, result.get())
    }

    private fun awaitWaiting(thread: Thread?) {
        requireNotNull(thread)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
        while (thread.state != Thread.State.WAITING && System.nanoTime() < deadline) {
            Thread.yield()
        }
        assertEquals("worker never entered the slot wait", Thread.State.WAITING, thread.state)
    }
}
