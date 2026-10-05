package com.sidescreen.app

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Pure decision logic for when a [VideoDecoder] has stopped being able to
 * recover on its own and must be replaced.
 *
 * Everything here is a total function over plain values: no Android types, no
 * threads, no clocks. `VideoDecoder.kt` owns all mutable state and delegates
 * only the "should I give up?" question here, so the rules are unit-testable
 * and the caller can never drift from the tested policy.
 *
 * Two failure classes are covered:
 *
 *  - **Rejected input.** A frame larger than the codec's input buffer cannot be
 *    fed. The only way to hand the input index back is to submit an empty
 *    access unit, and if the stream keeps producing frames the configured size
 *    can never hold them, so the pipeline itself is wrong and has to be rebuilt
 *    at a different size.
 *  - **No output progress.** A decoder that is fed frames continuously but
 *    produces none has wedged: every queued frame is stuck behind a reference
 *    the codec will never get. The demand threshold is what separates this from
 *    a healthy idle stream — the host deliberately sends nothing for an
 *    unchanged desktop, and an idle decoder that has not been asked to decode
 *    anything is not broken.
 */
internal object DecoderRecoveryPolicy {
    /**
     * Stable reason prefixes reported through `VideoDecoder.onDecoderFailure`.
     * Callers that want to react differently per cause (for example, lowering
     * the negotiated resolution on [REASON_INPUT_TOO_LARGE]) match on the
     * prefix; the remainder of the string is human-readable detail.
 */
    const val REASON_CODEC_ERROR = "codec-error"
    const val REASON_INPUT_TOO_LARGE = "input-too-large"
    const val REASON_NO_OUTPUT = "no-output"

    /** Demand and monotonic-time budgets; idle streams never spend them. */
    const val MIN_INPUT_DEMAND_FRAMES = 8L
    const val MIN_INPUT_WAIT_TIMEOUTS = 2L
    const val NO_OUTPUT_TIMEOUT_MS = 4_000L

    /** Fresh demand after a quiet desktop gets its own warmup grace. */
    fun outputSilenceMs(nowMs: Long, lastOutputMs: Long, firstDemandMs: Long): Long =
        (nowMs - maxOf(lastOutputMs, firstDemandMs)).coerceAtLeast(0L)

    enum class InputFrameAction {
        /** The frame fits the codec's input buffer and may be queued. */
        QUEUE,

        /** The frame cannot fit; the input slot must be returned and the
         *  pipeline reported as unable to continue at this size. */
        REJECT,
    }

    /**
     * Whether [frameSize] can be copied into an input buffer of [capacity].
     * A negative size is treated as a protocol error (REJECT) rather than a
     * silent no-op so the caller surfaces it.
     */
    fun inputFrameAction(
        frameSize: Int,
        capacity: Int,
    ): InputFrameAction =
        if (frameSize < 0 || frameSize > capacity) InputFrameAction.REJECT else InputFrameAction.QUEUE

    /**
     * What the decoder does with a frame the codec cannot accept, in the exact
     * order it must happen: hand the client-owned input index back to the codec
     * *first*, then produce the failure reason for the owner.
     *
     * The order is the whole point. `getInputBuffer()` marks the index
     * client-owned and `queueInputBuffer()` is the only call that returns it to
     * the codec's input pool, so a rejected frame that never queues leaks one
     * of the codec's few input slots. After a handful of rejections the codec
     * cannot be fed at all and the screen stays black no matter how many
     * keyframes are requested.
     *
     * [returnSlot] performs that hand-back. It is injected so the ordering and
     * exactly-once property are testable without a device, and it is invoked
     * defensively: a slot return that itself throws must not suppress the
     * failure report, because the report is the only thing that can rebuild the
     * pipeline.
     */
    fun rejectOversizeInput(
        frameSize: Int,
        capacity: Int,
        width: Int,
        height: Int,
        returnSlot: () -> Unit,
    ): String {
        runCatching(returnSlot)
        return inputTooLargeReason(frameSize, capacity, width, height)
    }

    /**
     * One-shot delivery for `VideoDecoder.onDecoderFailure`.
     *
     * The decoder can fail before its owner has bound the callback — the
     * pipeline is constructed on a background thread and the callback is
     * attached a moment later. A plain latch would consume the failure during
     * that window and leave a permanently dead decoder that reports nothing,
     * which is the black-screen failure mode all over again. So a failure
     * raised while no sink is attached is *held* and delivered as soon as one
     * is, and delivered exactly once either way.
     */
    class FailureSink {
        private val delivered = AtomicBoolean(false)
        private val pending = AtomicReference<String?>(null)
        @Volatile private var sink: ((String) -> Unit)? = null

        /** The currently attached owner callback, for [VideoDecoder]'s getter. */
        val boundSink: ((String) -> Unit)?
            get() = sink

        /** True once a failure has been reported, whether held or delivered. */
        val hasReported: Boolean
            get() = delivered.get()

        /**
         * Report [reason] to the bound sink. A second call for the same failure
         * is ignored; a call with no sink bound is held, not lost. Parking the
         * reason before draining is what makes the hold-then-bind race safe:
         * either side sees the other's state, so the reason cannot be stranded
         * in [pending] after a sink is already attached.
         */
        fun report(reason: String) {
            if (!delivered.compareAndSet(false, true)) return
            pending.set(reason)
            drainIfBound()
        }

        /**
         * Attach the owner callback, flushing a failure that was raised before
         * the owner was ready to receive it.
         */
        fun bind(target: ((String) -> Unit)?) {
            sink = target
            drainIfBound()
        }

        /** Stop reporting entirely, for a decoder being torn down. */
        fun detach() {
            sink = null
            pending.set(null)
        }

        /**
         * Re-arm for a new decoder generation — a rebuilt codec may report its
         * own failure and must not inherit the previous codec's one-shot latch.
         * A reason that was being held for a late-binding owner is flushed here
         * rather than dropped, so an in-place rebuild cannot swallow the failure
         * that motivated it.
         */
        fun reset() {
            delivered.set(false)
            drainIfBound()
        }

        private fun drainIfBound() {
            val target = sink ?: return
            val held = pending.getAndSet(null) ?: return
            target(held)
        }
    }

    /**
     * Whether the decoder was fed frames, produced nothing for
     * [msSinceLastOutput] ms, and should now be reported as wedged.
     *
     * Three inputs because no single counter can prove the wedge on its own:
     *
     *  - At least one frame must have actually been accepted
     *    ([inputFramesSinceOutput] > 0). That is the proof of real demand: a
     *    host that sends nothing for an unchanged desktop, or a stream still
     *    waiting for its first IDR, leaves this at zero and stays healthy no
     *    matter how long the silence runs.
     *  - The accepted count must have reached [MIN_INPUT_DEMAND_FRAMES], *or*
     *    every attempt since then has failed to find an input buffer
     *    ([feedAttemptsSinceOutput] - [inputFramesSinceOutput] >=
     *    [MIN_INPUT_WAIT_TIMEOUTS] with [inputWaitTimeoutsSinceOutput] > 0). A
     *    decoder with only a handful of input buffers absorbs four frames,
     *    produces nothing, and can never accept a fifth, so an accepted-count
     *    threshold alone is unreachable exactly in the case that matters most.
     *    The timeout clause is what a codec that has stopped answering looks
     *    like, and requiring real timeouts keeps a momentary hand-off race from
     *    satisfying it.
     *  - The elapsed time proves the silence is not cold-start backpressure that
     *    is about to clear.
     *
     * [alreadyReported] keeps the report one-shot for a generation.
     */
    fun shouldReportNoOutput(
        inputFramesSinceOutput: Long,
        feedAttemptsSinceOutput: Long = inputFramesSinceOutput,
        inputWaitTimeoutsSinceOutput: Long = 0L,
        msSinceLastOutput: Long,
        alreadyReported: Boolean,
    ): Boolean {
        if (alreadyReported) return false
        if (inputFramesSinceOutput <= 0L) return false
        if (msSinceLastOutput < NO_OUTPUT_TIMEOUT_MS) return false
        if (inputFramesSinceOutput >= MIN_INPUT_DEMAND_FRAMES) return true
        // Accepted-but-frozen: the codec spent its input buffers and now has
        // nothing to offer. Attempts that never reached the codec do not count
        // as demand, so the timeout clause has to carry the case on its own.
        return inputWaitTimeoutsSinceOutput >= MIN_INPUT_WAIT_TIMEOUTS &&
            feedAttemptsSinceOutput - inputFramesSinceOutput >= MIN_INPUT_WAIT_TIMEOUTS
    }

    /** Failure detail for an internal `MediaCodec` error. */
    fun codecErrorReason(diagnosticInfo: String?): String =
        "$REASON_CODEC_ERROR: ${diagnosticInfo?.takeIf { it.isNotBlank() } ?: "unknown"}"

    /** Failure detail for a frame the codec's input buffer cannot hold. */
    fun inputTooLargeReason(
        frameSize: Int,
        capacity: Int,
        width: Int,
        height: Int,
    ): String = "$REASON_INPUT_TOO_LARGE: frame=$frameSize capacity=$capacity ${width}x$height"

    /** Failure detail for a fed decoder that stopped producing output. */
    fun noOutputReason(
        inputFramesSinceOutput: Long,
        msSinceLastOutput: Long,
    ): String =
        "$REASON_NO_OUTPUT: $inputFramesSinceOutput frames fed, " +
            "no output for ${msSinceLastOutput}ms"
}
