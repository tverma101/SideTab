package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class DecoderLimitsWireContractTest {
    private val serverToClientTags =
        mapOf(
            0 to "videoFrame",
            1 to "displayConfig",
            5 to "pong",
            6 to "videoFrameWithMetadata",
            10 to "codecSelected",
            11 to "bright",
            13 to "serverSupportsStylus",
        )

    @Test
    fun decoderLimitsUseTheHostsCurrentTag() {
        assertEquals(15, StreamClient.MESSAGE_CLIENT_DECODER_LIMITS)
    }

    @Test
    fun decoderLimitsTagCannotCollideWithAServerToClientMessage() {
        // The client dispatches on the tag alone, and the host's unknown-tag
        // arm skips a single byte — a shared tag desyncs the stream by the
        // remaining payload bytes.
        serverToClientTags.forEach { (tag, name) ->
            assertNotEquals(
                "decoder-limits tag collides with server->client $name",
                tag,
                StreamClient.MESSAGE_CLIENT_DECODER_LIMITS,
            )
        }
    }

    @Test
    fun decoderLimitsTagCannotCollideWithAnotherClientMessage() {
        listOf(
            2 to "touchEvent",
            3 to "clientSupportsBrightness",
            4 to "ping",
            7 to "keyframeRequest",
            8 to "clientSupportsFrameMetadata",
            9 to "clientAvcOnly",
            12 to "clientSupportsStylus",
            14 to "stylusEvent",
        ).forEach { (tag, name) ->
            assertNotEquals(
                "decoder-limits tag collides with client->server $name",
                tag,
                StreamClient.MESSAGE_CLIENT_DECODER_LIMITS,
            )
        }
    }
}
