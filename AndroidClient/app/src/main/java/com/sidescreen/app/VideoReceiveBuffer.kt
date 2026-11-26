package com.sidescreen.app

/**
 * Storage owned by one socket read loop. Frames are delivered synchronously
 * and the decoder copies them into MediaCodec before the next socket read.
 */
internal class VideoReceiveBuffer {
    private var reusable = ByteArray(0)

    fun acquire(size: Int): ByteArray {
        // Large keyframes still fit the wire protocol. A burst should never
        // inflate the storage retained for the rest of an idle session.
        if (size > MAX_RETAINED_BYTES) return ByteArray(size)
        if (size > reusable.size) {
            val capacity = maxOf(MIN_RETAINED_BYTES, Integer.highestOneBit(size - 1) shl 1)
            reusable = ByteArray(capacity)
        }
        return reusable
    }

    companion object {
        private const val MIN_RETAINED_BYTES = 64 * 1024
        private const val MAX_RETAINED_BYTES = 1024 * 1024
    }
}
