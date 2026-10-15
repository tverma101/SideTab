package com.sidescreen.app

/** Serializes callback side effects with the generation change that retires them. */
internal class ConnectionGenerationFence {
    private val lock = Any()
    private var generation = 0L

    val currentGeneration: Long
        get() = synchronized(lock) { generation }

    fun <T> withLock(action: () -> T): T = synchronized(lock, action)

    fun advance(): Long = synchronized(lock) {
        generation += 1
        generation
    }

    fun runIfCurrent(
        expectedGeneration: Long,
        predicate: () -> Boolean = { true },
        action: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (generation != expectedGeneration || !predicate()) return@synchronized false
        action()
        true
    }
}
