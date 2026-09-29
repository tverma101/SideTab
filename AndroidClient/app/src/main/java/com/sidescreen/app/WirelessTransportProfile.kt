package com.sidescreen.app

/** Socket sizing for the bounded wireless video path. */
object WirelessTransportProfile {
    /** Enough TCP window for the 40 Mbps wireless profile without ~200 ms of
     * kernel buffering when a panel or scheduler briefly falls behind. */
    const val VIDEO_SOCKET_RECEIVE_BUFFER_BYTES = 256 * 1024

    /** Keep app-side read-ahead below one 60-Hz frame burst at the wireless
     * ceiling. MediaCodec remains the bounded handoff point. */
    const val VIDEO_STREAM_BUFFER_BYTES = 64 * 1024
}
