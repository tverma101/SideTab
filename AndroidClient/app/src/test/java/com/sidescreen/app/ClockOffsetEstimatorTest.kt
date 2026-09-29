package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClockOffsetEstimatorTest {
    private val ns = 1_000_000L

    @Test
    fun noOffsetBeforeAPongIsAnswered() {
        val estimator = ClockOffsetEstimator()

        assertNull(estimator.offsetNs)
        assertNull(estimator.hostEventAgeNs(hostEventNs = 5_000_000_000L, localNowNs = 1_000_000_000L))
        assertEquals(-1.0, estimator.sampleRttMs, 0.0)
    }

    @Test
    fun symmetricSampleRecoversTheClockOffset() {
        val estimator = ClockOffsetEstimator()
        // Host clock runs 10 s ahead of the device's monotonic clock.
        val clientSent = 100_000_000_000L
        val hostSend = clientSent + 10_000_000_000L + 5 * ns
        val arrival = clientSent + 10 * ns

        val offset = estimator.offer(clientSent, hostSend, arrival)

        // Midpoint correction removes this sample's one-way delay.
        assertEquals(10_000_000_000L, offset)
        assertEquals(10.0, estimator.sampleRttMs, 0.001)
    }

    @Test
    fun theLowestRoundTripSampleWins() {
        val estimator = ClockOffsetEstimator()
        val clientSent = 1_000_000_000L
        val offset = 7_000_000_000L

        estimator.offer(clientSent, hostSendNs = clientSent + offset + 50 * ns, arrivalNs = clientSent + 100 * ns)
        estimator.offer(clientSent, hostSendNs = clientSent + offset + 2 * ns, arrivalNs = clientSent + 4 * ns)
        estimator.offer(clientSent, hostSendNs = clientSent + offset + 30 * ns, arrivalNs = clientSent + 60 * ns)

        assertEquals(offset, estimator.offsetNs)
    }

    @Test
    fun outOfOrderReplyIsIgnoredRatherThanPoisoningTheEstimate() {
        val estimator = ClockOffsetEstimator()
        val clientSent = 1_000_000_000L

        estimator.offer(clientSent, hostSendNs = 8_000_000_000L, arrivalNs = clientSent + 4 * ns)
        val poisoned = estimator.offer(clientSent, hostSendNs = 1L, arrivalNs = clientSent - 4 * ns)

        assertEquals(8_000_000_000L - (clientSent + 2 * ns), poisoned)
        assertEquals(4.0, estimator.sampleRttMs, 0.001)
    }

    @Test
    fun staleOffsetCanNeverReportNegativeLatency() {
        val estimator = ClockOffsetEstimator()
        val clientSent = 1_000_000_000L
        val offset = 50_000_000_000L
        estimator.offer(clientSent, hostSendNs = clientSent + offset, arrivalNs = clientSent)

        // A host event whose converted instant is in the future means the
        // offset is stale, not that the frame is from the future.
        assertNull(estimator.hostEventAgeNs(hostEventNs = clientSent + offset + 10 * ns, localNowNs = clientSent))
        assertEquals(10 * ns, estimator.hostEventAgeNs(hostEventNs = clientSent + offset, localNowNs = clientSent + 10 * ns))
    }

    // MARK: - Re-validation
    //
    // The estimator used to latch the lowest-RTT sample forever. An early
    // 200 microsecond sample on an idle network is unbeatable, so after the host
    // slept (its clock is mach_absolute_time, which stops advancing) the
    // estimate stayed wrong for the rest of the session and every derived
    // latency was wrong with it.
    //
    // Samples below are symmetric: the host read its clock half a round trip
    // after we sent, so the midpoint correction recovers [trueOffset] exactly
    // and the bracket is [trueOffset - rtt/2, trueOffset + rtt/2].

    private val trueOffset = 7_000_000_000L

    /**
     * The host clock moved relative to ours. No round trip can reconcile the
     * new bracket with the old estimate, so the new reading is adopted
     * immediately even though it has a far worse RTT.
     */
    @Test
    fun aDisjointBracketProvesDriftAndOverridesABetterSample() {
        val estimator = ClockOffsetEstimator()
        val clientSent = 1_000_000_000L

        // A very tight sample: true offset 7s, 2ms round trip.
        estimator.offer(
            clientSentNs = clientSent,
            hostSendNs = clientSent + trueOffset + 1 * ns,
            arrivalNs = clientSent + 2 * ns,
        )
        assertEquals(trueOffset, estimator.offsetNs)

        // The Mac slept and its clock now reads 3s ahead. This bracket is
        // nowhere near 7s, so drift is proven regardless of its 400ms RTT.
        val later = clientSent + 5_000_000_000L
        val offset = estimator.offer(
            clientSentNs = later,
            hostSendNs = later + 3_000_000_000L + 200 * ns,
            arrivalNs = later + 400 * ns,
        )

        assertEquals(3_000_000_000L, offset)
        // The tighter reading is gone, which is the point: a wrong offset makes
        // every derived latency wrong too.
        assertEquals(400.0, estimator.sampleRttMs, 0.001)
    }

    /**
     * A slow relative slip stays inside the bracket, so disjointness cannot
     * prove drift. The age window is the backstop: a stale precise estimate is
     * worse than a fresher loose one. The slip here (100ms) is deliberately
     * smaller than the 900ms round trip's own uncertainty, which is exactly
     * the case only re-validation can catch.
     */
    @Test
    fun anExpiredSampleIsReplacedByAFresherLooserReading() {
        val estimator = ClockOffsetEstimator()
        estimator.maxSampleAgeNs = 10_000_000_000L
        val clientSent = 1_000_000_000L

        estimator.offer(
            clientSentNs = clientSent,
            hostSendNs = clientSent + trueOffset + 1 * ns,
            arrivalNs = clientSent + 2 * ns,
        )
        assertEquals(trueOffset, estimator.offsetNs)

        // Well inside the window with a much worse RTT: the tight sample holds.
        val inside = clientSent + 1_000_000_000L
        assertEquals(
            trueOffset,
            estimator.offer(
                clientSentNs = inside,
                hostSendNs = inside + trueOffset + 450 * ns,
                arrivalNs = inside + 900 * ns,
            ),
        )

        // Past the window the offset has slipped 100ms. The new bracket still
        // contains the old estimate, so only the expiry rule can catch this.
        val slipped = trueOffset - 100 * ns
        val after = clientSent + 20_000_000_000L
        assertEquals(
            slipped,
            estimator.offer(
                clientSentNs = after,
                hostSendNs = after + slipped + 450 * ns,
                arrivalNs = after + 900 * ns,
            ),
        )
    }

    /**
     * Re-validation must not defeat the original guarantee: while the current
     * estimate still holds, a better round trip still wins.
     */
    @Test
    fun revalidationDoesNotDisplaceAStillValidTightSample() {
        val estimator = ClockOffsetEstimator()
        val clientSent = 1_000_000_000L
        estimator.offer(
            clientSentNs = clientSent,
            hostSendNs = clientSent + trueOffset + 50 * ns,
            arrivalNs = clientSent + 100 * ns,
        )

        val tighter = clientSent + 2_000_000_000L
        assertEquals(
            trueOffset,
            estimator.offer(
                clientSentNs = tighter,
                hostSendNs = tighter + trueOffset + 2 * ns,
                arrivalNs = tighter + 4 * ns,
            ),
        )
        assertEquals(4.0, estimator.sampleRttMs, 0.001)
    }
}
