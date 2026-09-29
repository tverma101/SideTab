package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlPingProbeTest {
    @Test
    fun pongEchoingThePacketTimestampAnswersAProbeArmedAfterTheWrite() {
        // sendPing stamps the packet before the write and arms the deadline
        // after it. The host echoes the packet's value, never the arming time.
        val probe = ControlPingProbe(connectionGeneration = 3L, wireTimestampNs = 1_000L, armedAtNs = 1_750L)
        assertTrue(probe.isAnsweredBy(generation = 3L, echoedTimestampNs = 1_000L))
        assertFalse(probe.isAnsweredBy(generation = 3L, echoedTimestampNs = 1_750L))
    }

    @Test
    fun pongFromAnotherPingOrConnectionDoesNotAnswer() {
        val probe = ControlPingProbe(connectionGeneration = 3L, wireTimestampNs = 1_000L, armedAtNs = 1_750L)
        assertFalse(probe.isAnsweredBy(generation = 3L, echoedTimestampNs = 999L))
        assertFalse(probe.isAnsweredBy(generation = 2L, echoedTimestampNs = 1_000L))
    }

    @Test
    fun deadlineRunsFromTheArmingTime() {
        val probe = ControlPingProbe(connectionGeneration = 1L, wireTimestampNs = 1_000L, armedAtNs = 5_000L)
        assertFalse(
            LivenessProbePolicy.isExpired(
                sentAtNs = probe.armedAtNs,
                nowNs = 9_000L,
                timeoutNs = 4_000L,
                paused = false,
            ),
        )
        assertTrue(
            LivenessProbePolicy.isExpired(
                sentAtNs = probe.armedAtNs,
                nowNs = 9_001L,
                timeoutNs = 4_000L,
                paused = false,
            ),
        )
    }
}
