package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderRecoveryPolicyTest {
    // MARK: - Rejected input

    @Test
    fun aFrameThatFitsTheInputBufferIsQueued() {
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.QUEUE,
            DecoderRecoveryPolicy.inputFrameAction(frameSize = 1024, capacity = 4096),
        )
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.QUEUE,
            // Exactly filling the buffer is still legal.
            DecoderRecoveryPolicy.inputFrameAction(frameSize = 4096, capacity = 4096),
        )
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.QUEUE,
            DecoderRecoveryPolicy.inputFrameAction(frameSize = 0, capacity = 4096),
        )
    }

    @Test
    fun aFrameLargerThanTheInputBufferIsRejected() {
        // The host may send up to 5 MB while KEY_MAX_INPUT_SIZE for 1920x1200 is
        // only ~3.45 MB, so an oversized IDR is reachable in normal operation.
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.REJECT,
            DecoderRecoveryPolicy.inputFrameAction(frameSize = 5 * 1024 * 1024, capacity = 1920 * 1200 * 3 / 2),
        )
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.REJECT,
            DecoderRecoveryPolicy.inputFrameAction(frameSize = 1, capacity = 0),
        )
    }

    @Test
    fun aNegativeFrameSizeIsRejectedRatherThanSilentlyDropped() {
        assertEquals(
            DecoderRecoveryPolicy.InputFrameAction.REJECT,
            DecoderRecoveryPolicy.inputFrameAction(frameSize = -1, capacity = 4096),
        )
    }

    // MARK: - Output-progress watchdog

    @Test
    fun anIdleDecoderIsHealthyHoweverLongTheSilence() {
        // The host deliberately sends nothing for an unchanged desktop, so a
        // decoder that was never fed anything must never be reported.
        assertFalse(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = 0,
                msSinceLastOutput = 10 * 60_000L,
                alreadyReported = false,
            ),
        )
    }

    @Test
    fun aFewFedFramesAreNotEnoughToDeclareAWedge() {
        assertFalse(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = DecoderRecoveryPolicy.MIN_INPUT_DEMAND_FRAMES - 1,
                msSinceLastOutput = DecoderRecoveryPolicy.NO_OUTPUT_TIMEOUT_MS * 10,
                alreadyReported = false,
            ),
        )
    }

    @Test
    fun fedFramesInsideTheTimeoutAreBackpressureNotAWedge() {
        assertFalse(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = 60,
                msSinceLastOutput = DecoderRecoveryPolicy.NO_OUTPUT_TIMEOUT_MS - 1,
                alreadyReported = false,
            ),
        )
    }

    @Test
    fun sustainedDemandWithNoOutputIsReported() {
        assertTrue(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = DecoderRecoveryPolicy.MIN_INPUT_DEMAND_FRAMES,
                msSinceLastOutput = DecoderRecoveryPolicy.NO_OUTPUT_TIMEOUT_MS,
                alreadyReported = false,
            ),
        )
        assertTrue(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = 5_000,
                msSinceLastOutput = 60_000L,
                alreadyReported = false,
            ),
        )
    }

    @Test
    fun theWatchdogIsOneShotPerGeneration() {
        assertFalse(
            DecoderRecoveryPolicy.shouldReportNoOutput(
                inputFramesSinceOutput = 5_000,
                msSinceLastOutput = 60_000L,
                alreadyReported = true,
            ),
        )
    }

    @Test
    fun theTimeoutIsLongerThanAColdFirstKeyframeAndShorterThanTransportRetirement() {
        assertTrue(DecoderRecoveryPolicy.NO_OUTPUT_TIMEOUT_MS >= 1_000L)
        assertTrue(DecoderRecoveryPolicy.MIN_INPUT_DEMAND_FRAMES >= 2L)
        // VideoLivenessPolicy retires a transport after 20 s per unanswered
        // probe; the decoder watchdog has to notice a wedged codec well before
        // that, or the black screen outlives the transport that could have
        // rebuilt it.
        assertTrue(DecoderRecoveryPolicy.NO_OUTPUT_TIMEOUT_MS < VideoLivenessPolicy.PROBE_TIMEOUT_NS / 1_000_000L)
    }

    @Test
    fun fourExhaustedInputSlotsStillTriggerRecovery() {
        assertTrue(DecoderRecoveryPolicy.shouldReportNoOutput(
            inputFramesSinceOutput = 4,
            feedAttemptsSinceOutput = 6,
            inputWaitTimeoutsSinceOutput = 2,
            msSinceLastOutput = 4_000,
            alreadyReported = false,
        ))
        assertFalse(DecoderRecoveryPolicy.shouldReportNoOutput(
            inputFramesSinceOutput = 4,
            feedAttemptsSinceOutput = 5,
            inputWaitTimeoutsSinceOutput = 1,
            msSinceLastOutput = 4_000,
            alreadyReported = false,
        ))
    }

    @Test
    fun newDemandAfterHoursOfIdleHasItsOwnWarmupGrace() {
        assertEquals(100L, DecoderRecoveryPolicy.outputSilenceMs(
            nowMs = 36_000_100L, lastOutputMs = 1_000L, firstDemandMs = 36_000_000L,
        ))
        assertEquals(4_000L, DecoderRecoveryPolicy.outputSilenceMs(
            nowMs = 36_004_000L, lastOutputMs = 1_000L, firstDemandMs = 36_000_000L,
        ))
    }

    // MARK: - Reason strings

    @Test
    fun reasonsCarryAStablePrefixTheOwnerCanMatchOn() {
        assertEquals(
            "codec-error: android.media.MediaCodec.error_-2147483648",
            DecoderRecoveryPolicy.codecErrorReason("android.media.MediaCodec.error_-2147483648"),
        )
        assertEquals(
            "input-too-large: frame=5242880 capacity=3456000 1920x1200",
            DecoderRecoveryPolicy.inputTooLargeReason(5 * 1024 * 1024, 1920 * 1200 * 3 / 2, 1920, 1200),
        )
        assertEquals(
            "no-output: 240 frames fed, no output for 9000ms",
            DecoderRecoveryPolicy.noOutputReason(240, 9_000L),
        )
    }

    @Test
    fun anAbsentCodecDiagnosticStillNamesTheCause() {
        assertEquals(
            "${DecoderRecoveryPolicy.REASON_CODEC_ERROR}: unknown",
            DecoderRecoveryPolicy.codecErrorReason(null),
        )
        assertEquals(
            "${DecoderRecoveryPolicy.REASON_CODEC_ERROR}: unknown",
            DecoderRecoveryPolicy.codecErrorReason("   "),
        )
    }

    // MARK: - The rejected-input ownership path
    //
    // The defect this covers is not a wrong constant: `getInputBuffer()` marks
    // an index client-owned and only `queueInputBuffer()` returns it to the
    // codec's pool. A rejected frame that just returns leaked one of a handful
    // of input slots per rejection until the decoder could never be fed again —
    // a permanent black screen. These tests assert the hand-back actually
    // happens, happens before the report, and happens even when it throws.

    @Test
    fun aRejectedFrameHandsTheInputSlotBackBeforeReporting() {
        val order = mutableListOf<String>()
        val reason =
            DecoderRecoveryPolicy.rejectOversizeInput(
                frameSize = 5 * 1024 * 1024,
                capacity = 1920 * 1200 * 3 / 2,
                width = 1920,
                height = 1200,
                returnSlot = { order.add("return-slot") },
            )
        order.add("report")
        assertEquals(listOf("return-slot", "report"), order)
        assertEquals(
            "${DecoderRecoveryPolicy.REASON_INPUT_TOO_LARGE}: " +
                "frame=5242880 capacity=3456000 1920x1200",
            reason,
        )
    }

    @Test
    fun aRejectedFrameStillReportsWhenTheSlotHandBackItselfFails() {
        val reason =
            DecoderRecoveryPolicy.rejectOversizeInput(
                frameSize = 5 * 1024 * 1024,
                capacity = 1024,
                width = 1920,
                height = 1200,
                returnSlot = { throw IllegalStateException("codec already gone") },
            )
        // Losing the slot is survivable; losing the report is the black screen.
        assertTrue(reason.startsWith(DecoderRecoveryPolicy.REASON_INPUT_TOO_LARGE))
    }

    @Test
    fun repeatedRejectionsHandBackEverySlotTheyConsumed() {
        var returned = 0
        repeat(20) {
            DecoderRecoveryPolicy.rejectOversizeInput(
                frameSize = 9 * 1024 * 1024,
                capacity = 1024,
                width = 1920,
                height = 1200,
                returnSlot = { returned++ },
            )
        }
        assertEquals(20, returned)
    }

    // MARK: - One-shot, hold-until-bound failure delivery

    @Test
    fun aFailureRaisedBeforeTheOwnerAttachesIsHeldThenDeliveredOnAttach() {
        val sink = DecoderRecoveryPolicy.FailureSink()
        assertNull(sink.boundSink)
        // The pipeline is built on a background thread; this is the window in
        // which a plain latch would consume the failure and leave a permanently
        // dead, unreported decoder.
        sink.report("codec-error: boom")
        assertTrue(sink.hasReported)
        val received = mutableListOf<String>()
        sink.bind { received.add(it) }
        assertEquals(listOf("codec-error: boom"), received)
        assertEquals(1, received.size)
    }

    @Test
    fun aFailureWithAnAttachedOwnerIsDeliveredImmediatelyAndOnlyOnce() {
        val sink = DecoderRecoveryPolicy.FailureSink()
        val received = mutableListOf<String>()
        sink.bind { received.add(it) }
        sink.report("no-output: 240 frames fed, no output for 9000ms")
        sink.report("codec-error: later")
        assertEquals(listOf("no-output: 240 frames fed, no output for 9000ms"), received)
        assertTrue(sink.hasReported)
    }

    @Test
    fun aRebuildReArmsTheLatchAndFlushesAnyHeldFailure() {
        val sink = DecoderRecoveryPolicy.FailureSink()
        val received = mutableListOf<String>()
        sink.bind { received.add(it) }
        sink.report("codec-error: boom")
        sink.reset()
        // The new generation may report its own failure.
        sink.report("no-output: 8 frames fed, no output for 4000ms")
        assertEquals(
            listOf(
                "codec-error: boom",
                "no-output: 8 frames fed, no output for 4000ms",
            ),
            received,
        )
    }

    @Test
    fun detachingSilencesARetiringDecoder() {
        val sink = DecoderRecoveryPolicy.FailureSink()
        val received = mutableListOf<String>()
        sink.bind { received.add(it) }
        sink.detach()
        assertNull(sink.boundSink)
        sink.report("codec-error: after teardown")
        // Nothing new is delivered to a pipeline the owner already replaced.
        assertTrue(received.isEmpty())
    }
}
