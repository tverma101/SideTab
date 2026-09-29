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
}
