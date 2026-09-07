package com.sidescreen.app

/** Socket sizing for the bounded wireless video path. */
object WirelessTransportProfile {
    const val VIDEO_SOCKET_RECEIVE_BUFFER_BYTES = 1 * 1024 * 1024
    const val VIDEO_STREAM_BUFFER_BYTES = 256 * 1024
}
