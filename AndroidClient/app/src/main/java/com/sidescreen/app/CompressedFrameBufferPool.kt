package com.sidescreen.app

/**
 * Single-slot pool for compressed video frames.
 *
 * StreamClient reads one complete TCP frame and invokes its frame callback
 * synchronously before reading the next frame, so it does not need a fleet of
 * simultaneously borrowed compressed buffers. Retaining only the largest
 * returned buffer keeps steady-state allocation-free while bounding retained
 * compressed-frame storage to one frame instead of up to eight large arrays.
 */
internal class CompressedFrameBufferPool {
    private val lock = Any()
    private var retained: ByteArray? = null

    fun acquire(minSize: Int): ByteArray {
        require(minSize > 0) { "minSize must be positive" }
        synchronized(lock) {
            val candidate = retained
            retained = null
            if (candidate != null && candidate.size >= minSize) {
                return candidate
            }
        }
        return ByteArray(minSize)
    }

    fun release(buffer: ByteArray) {
        synchronized(lock) {
            val current = retained
            if (current == null || buffer.size > current.size) {
                retained = buffer
            }
        }
    }

    internal fun retainedSizeForTest(): Int = synchronized(lock) { retained?.size ?: 0 }
}
