package com.sidescreen.app

/**
 * A bounded hand-off slot for a producer that may outpace one consumer.
 *
 * Publishing blocks only while an older value is still waiting to be taken.
 * Closing the slot wakes both sides.
 *
 * Lossiness is deliberate and lossy on the *new* value: a producer whose wait
 * is interrupted, or which arrives after the slot closed, drops its own value
 * and returns `false`. Any value already queued is not touched — it is handed
 * to [close]'s `onDiscard` instead, so an in-flight value is never silently
 * destroyed by a losing producer.
 */
internal class BlockingSingleSlot<T : Any> {
    private val lock = Object()
    private var value: T? = null
    private var closed = false

    fun publish(
        next: T,
        isOpen: () -> Boolean,
    ): Boolean = synchronized(lock) {
        while (!closed && isOpen() && value != null) {
            try {
                lock.wait()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return@synchronized false
            }
        }
        if (closed || !isOpen()) return@synchronized false
        value = next
        lock.notifyAll()
        true
    }

    fun take(isOpen: () -> Boolean): T? = synchronized(lock) {
        while (!closed && isOpen() && value == null) {
            try {
                lock.wait()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return@synchronized null
            }
        }
        if (closed || !isOpen()) return@synchronized null
        val current = value
        value = null
        lock.notifyAll()
        current
    }

    /** Close the slot and transfer any queued value to [onDiscard]. */
    fun close(onDiscard: (T) -> Unit) {
        val discarded = synchronized(lock) {
            if (closed) return@synchronized null
            closed = true
            val current = value
            value = null
            lock.notifyAll()
            current
        }
        discarded?.let(onDiscard)
    }
}
