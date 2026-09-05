package com.sidescreen.app

import kotlin.math.max
import kotlin.math.sqrt

/**
 * Allocation-free rolling frame cadence statistics.
 *
 * The decoder calls [add] once per rendered frame. Timestamps live in a fixed
 * primitive ring and statistics are computed in one pass only when an update is
 * due, avoiding boxed Longs and temporary collections on the render thread.
 */
internal class FrameTimingWindow(
    private val capacity: Int = 120,
    private val minSamples: Int = 60,
    private val emitEvery: Int = 60,
) {
    init {
        require(capacity >= 2)
        require(minSamples in 2..capacity)
        require(emitEvery >= 1)
    }

    private val timestamps = LongArray(capacity)
    private var size = 0
    private var writeIndex = 0
    private var samplesSinceEmission = 0

    var fps: Double = 0.0
        private set

    var stdDevMs: Double = 0.0
        private set

    /** Returns true only when [fps] and [stdDevMs] were refreshed. */
    fun add(timestampNs: Long): Boolean {
        timestamps[writeIndex] = timestampNs
        writeIndex = (writeIndex + 1) % capacity
        if (size < capacity) size++
        samplesSinceEmission++

        if (size < minSamples || samplesSinceEmission < emitEvery) return false

        val oldestIndex = if (size == capacity) writeIndex else 0
        var previous = timestamps[oldestIndex]
        var deltaCount = 0
        var sumMs = 0.0
        var sumSquaresMs = 0.0

        for (offset in 1 until size) {
            val index = (oldestIndex + offset) % capacity
            val current = timestamps[index]
            val deltaNs = current - previous
            previous = current

            // System.nanoTime() should be monotonic. Ignore equal/out-of-order
            // samples rather than producing infinity or a negative FPS if a
            // platform clock ever violates that assumption.
            if (deltaNs <= 0L) continue

            val deltaMs = deltaNs / 1_000_000.0
            sumMs += deltaMs
            sumSquaresMs += deltaMs * deltaMs
            deltaCount++
        }

        if (deltaCount == 0) return false
        val averageMs = sumMs / deltaCount
        if (averageMs <= 0.0) return false

        val variance = max(0.0, sumSquaresMs / deltaCount - averageMs * averageMs)
        fps = 1000.0 / averageMs
        stdDevMs = sqrt(variance)
        samplesSinceEmission = 0
        return true
    }

    fun reset() {
        size = 0
        writeIndex = 0
        samplesSinceEmission = 0
        fps = 0.0
        stdDevMs = 0.0
    }
}
