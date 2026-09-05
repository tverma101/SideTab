package com.sidescreen.app

import android.os.SystemClock

/** Two floats packed into one unboxed Long on the hot prediction path. */
@JvmInline
value class PredictedPosition private constructor(private val packed: Long) {
    operator fun component1(): Float = Float.fromBits((packed ushr 32).toInt())

    operator fun component2(): Float = Float.fromBits(packed.toInt())

    companion object {
        fun of(
            x: Float,
            y: Float,
        ): PredictedPosition =
            PredictedPosition(
                (x.toRawBits().toLong() shl 32) or
                    (y.toRawBits().toLong() and 0xffff_ffffL),
            )
    }
}

/**
 * Predicts touch input position based on velocity to reduce perceived latency.
 *
 * The finger MOVE path runs at display/input cadence, so history is stored in
 * five primitive-array slots instead of allocating a TouchSample object for
 * every event. predictPosition() returns an inline packed value instead of a
 * Pair<Float, Float>, avoiding two boxed Floats plus the Pair allocation.
 */
class InputPredictor {
    private val sampleX = FloatArray(HISTORY_SIZE)
    private val sampleY = FloatArray(HISTORY_SIZE)
    private val sampleTimeNs = LongArray(HISTORY_SIZE)
    private var sampleCount = 0
    private var nextIndex = 0

    /** Add a new touch sample using the monotonic Android elapsed clock. */
    fun addSample(
        x: Float,
        y: Float,
    ) {
        addSample(x, y, SystemClock.elapsedRealtimeNanos())
    }

    /** Deterministic timestamp overload for local unit tests. */
    internal fun addSample(
        x: Float,
        y: Float,
        timestampNs: Long,
    ) {
        sampleX[nextIndex] = x
        sampleY[nextIndex] = y
        sampleTimeNs[nextIndex] = timestampNs
        nextIndex = (nextIndex + 1) % HISTORY_SIZE
        if (sampleCount < HISTORY_SIZE) sampleCount++
    }

    /**
     * Predict position after given latency in milliseconds using linear
     * extrapolation from the two newest samples.
     */
    fun predictPosition(latencyMs: Float): PredictedPosition {
        if (sampleCount == 0) return PredictedPosition.of(0f, 0f)

        val currentIndex = indexFromNewest(0)
        val currX = sampleX[currentIndex]
        val currY = sampleY[currentIndex]
        if (sampleCount < MIN_SAMPLES_FOR_PREDICTION) {
            return PredictedPosition.of(currX, currY)
        }

        val previousIndex = indexFromNewest(1)
        val dtMs = (sampleTimeNs[currentIndex] - sampleTimeNs[previousIndex]) / 1_000_000f
        if (dtMs < 0.1f) {
            return PredictedPosition.of(currX, currY)
        }

        val vx = (currX - sampleX[previousIndex]) / dtMs
        val vy = (currY - sampleY[previousIndex]) / dtMs
        return PredictedPosition.of(
            currX + vx * latencyMs,
            currY + vy * latencyMs,
        )
    }

    /** Get current velocity in units per second; debug/non-hot path. */
    fun getCurrentVelocity(): Pair<Float, Float> {
        if (sampleCount < 2) return Pair(0f, 0f)

        val currentIndex = indexFromNewest(0)
        val previousIndex = indexFromNewest(1)
        val dt = (sampleTimeNs[currentIndex] - sampleTimeNs[previousIndex]) / 1_000_000_000f
        return if (dt > 0f) {
            Pair(
                (sampleX[currentIndex] - sampleX[previousIndex]) / dt,
                (sampleY[currentIndex] - sampleY[previousIndex]) / dt,
            )
        } else {
            Pair(0f, 0f)
        }
    }

    /** Reset predictor state when a touch sequence ends. */
    fun reset() {
        sampleCount = 0
        nextIndex = 0
    }

    private fun indexFromNewest(offset: Int): Int =
        (nextIndex - 1 - offset + HISTORY_SIZE) % HISTORY_SIZE

    private companion object {
        const val HISTORY_SIZE = 5
        const val MIN_SAMPLES_FOR_PREDICTION = 2
    }
}
