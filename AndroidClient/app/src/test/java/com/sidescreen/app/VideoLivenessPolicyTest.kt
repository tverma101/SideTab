package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The video watchdog used to retire a working transport on a 6-second
 * read-loop timer whose only evidence was "did the read loop produce anything".
 * These tests pin the replacement: corroborated, read-path-aware retirement.
 */
class VideoLivenessPolicyTest {
    private val probeTimeout = VideoLivenessPolicy.PROBE_TIMEOUT_NS
    private val intervalNs = 3_000_000_000L

    // MARK: - The regression that caused the random disconnect

    /**
     * The reported bug: the tablet dropped its display at random while the Mac
     * kept streaming. A single unanswered probe must never close a socket.
     */
    @Test
    fun aSingleUnansweredProbeNeverRetiresTheTransport() {
        assertFalse(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = 1,
                readPathAlive = false,
                nowNs = probeTimeout + 1_000_000_000L,
                firstProbeNs = 1_000L,
                timeoutNs = probeTimeout,
            ),
        )
    }

    /**
     * Silence is the normal state of a healthy idle stream: the Mac suppresses
     * frames when ScreenCaptureKit reports the desktop has not changed. An
     * actively delivering read path outranks every timer here.
     */
    @Test
    fun anActivelyDeliveringReadPathIsNeverRetired() {
        val now = 1_000L + probeTimeout * 10
        assertFalse(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = 99,
                readPathAlive = true,
                nowNs = now,
                firstProbeNs = 1_000L,
                timeoutNs = probeTimeout,
            ),
        )
    }

    /**
     * A pong queued behind video data, a clean-frame gap, or a decoder stall
     * all produce exactly one miss. Two independent misses are the bar.
     */
    @Test
    fun twoUnansweredProbesRetireOnlyAfterTheBudgetElapses() {
        assertFalse(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = VideoLivenessPolicy.MAX_UNANSWERED_PROBES,
                readPathAlive = false,
                nowNs = 1_000L + probeTimeout,
                firstProbeNs = 1_000L,
                timeoutNs = probeTimeout,
            ),
        )
        assertTrue(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = VideoLivenessPolicy.MAX_UNANSWERED_PROBES,
                readPathAlive = false,
                nowNs = 1_000L + probeTimeout + 1,
                firstProbeNs = 1_000L,
                timeoutNs = probeTimeout,
            ),
        )
    }

    /**
     * The whole point of the change: the old budget was 6 s, which a real
     * 40 Mbps Wi-Fi link plus a blocked read loop blows through routinely.
     */
    @Test
    fun theBudgetIsComfortablyAboveTheOldSixSecondTimeout() {
        assertTrue(
            "probe timeout must exceed the 6s timer that caused the bug",
            probeTimeout >= 15_000_000_000L,
        )
        assertTrue(
            "worst-case detection must stay inside the host's 5-minute deadline",
            probeTimeout * VideoLivenessPolicy.MAX_UNANSWERED_PROBES < 300_000_000_000L,
        )
    }

    // MARK: - Clock guards

    @Test
    fun aMissingOrBackwardsClockNeverRetires() {
        assertFalse(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = 99,
                readPathAlive = false,
                nowNs = 9_000L,
                firstProbeNs = 0L,
                timeoutNs = probeTimeout,
            ),
        )
        assertFalse(
            VideoLivenessPolicy.shouldRetireTransport(
                unansweredProbes = 99,
                readPathAlive = false,
                nowNs = 1_000L,
                firstProbeNs = 9_000L,
                timeoutNs = probeTimeout,
            ),
        )
    }

    // MARK: - Read-path liveness

    @Test
    fun readPathIsAliveOnlyInsideItsOwnWindow() {
        val now = intervalNs * 10
        assertTrue(VideoLivenessPolicy.isReadPathAlive(now, now, staleAfterNs = intervalNs))
        assertTrue(
            VideoLivenessPolicy.isReadPathAlive(
                now - intervalNs + 1,
                now,
                staleAfterNs = intervalNs,
            ),
        )
        assertFalse(
            VideoLivenessPolicy.isReadPathAlive(now - intervalNs, now, staleAfterNs = intervalNs),
        )
    }

    @Test
    fun anUnstampedOrBackwardsReadPathIsNotAlive() {
        assertFalse(VideoLivenessPolicy.isReadPathAlive(0L, 100_000_000L, staleAfterNs = intervalNs))
        assertFalse(VideoLivenessPolicy.isReadPathAlive(100L, 50L, staleAfterNs = intervalNs))
    }

    // MARK: - Blocked writes

    /**
     * A write that blocks means the send buffer is wedged — genuine transport
     * evidence, reported on its own rather than folded into the silence counter.
     */
    @Test
    fun aBlockedWriteIsTransportEvidenceOnItsOwn() {
        assertFalse(VideoLivenessPolicy.isWriteBlocked(0L))
        assertFalse(
            VideoLivenessPolicy.isWriteBlocked(VideoLivenessPolicy.WRITE_BLOCKED_NS),
        )
        assertTrue(
            VideoLivenessPolicy.isWriteBlocked(VideoLivenessPolicy.WRITE_BLOCKED_NS + 1),
        )
        assertEquals(10_000_000_000L, VideoLivenessPolicy.WRITE_BLOCKED_NS)
    }
}
