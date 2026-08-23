package com.sidescreen.app

data class FrameTrace(
    val frameId: Long,
    val hostCaptureNs: Long,
    /** Host capture timestamp translated into Android's monotonic domain. */
    val captureNs: Long,
    val receivedNs: Long,
    val inputQueuedNs: Long = 0L,
    val outputAvailableNs: Long = 0L,
    val renderedNs: Long = 0L,
)

data class FrameTraceSummary(
    val count: Int,
    val p50Ms: Double,
    val p95Ms: Double,
    val p99Ms: Double,
    val maxMs: Double,
)

/** Bounded visible-latency window used by the runtime diagnostic log. */
class FrameTraceStats(private val maxSamples: Int = 240) {
    private val captureToRenderNs = ArrayDeque<Long>(maxSamples)

    @Synchronized
    fun add(trace: FrameTrace) {
        if (trace.captureNs <= 0L || trace.renderedNs < trace.captureNs) return
        if (captureToRenderNs.size == maxSamples) captureToRenderNs.removeFirst()
        captureToRenderNs.addLast(trace.renderedNs - trace.captureNs)
    }

    @Synchronized
    fun summary(): FrameTraceSummary? {
        if (captureToRenderNs.isEmpty()) return null
        val sorted = captureToRenderNs.sorted()
        fun percentile(fraction: Double): Double {
            val index = (kotlin.math.ceil(fraction * sorted.size).toInt() - 1)
                .coerceIn(0, sorted.lastIndex)
            return sorted[index] / 1_000_000.0
        }
        return FrameTraceSummary(
            count = sorted.size,
            p50Ms = percentile(0.50),
            p95Ms = percentile(0.95),
            p99Ms = percentile(0.99),
            maxMs = sorted.last() / 1_000_000.0,
        )
    }
}
