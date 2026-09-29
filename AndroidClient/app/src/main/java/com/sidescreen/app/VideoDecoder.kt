package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

private fun diagLog(msg: String) = DiagLog.log("VD", msg)

// Keep these optional codec hints as string keys so the app remains compatible
// with minSdk 26 without linking to newer MediaFormat fields.
private const val CODEC_KEY_LOW_LATENCY = "low-latency"
private const val CODEC_KEY_MAX_B_FRAMES = "max-bframes"

class VideoDecoder(
    private val surface: Surface,
    private val display: Display? = null,
    initialWidth: Int = 1920,
    initialHeight: Int = 1200,
    // Exposed so MainActivity can detect a codec-negotiation/decoder mismatch
    // and recreate the decoder (see MainActivity.onStreamCodecSelected).
    val mime: String = MediaFormat.MIMETYPE_VIDEO_HEVC,
    /** CfL path: configure with NO output surface and hand decoded Images
     *  to [onDecodedImage] via getOutputImage() — the only plane-accessible
     *  output on this SoC (ImageReader surfaces deliver opaque UBWC buffers
     *  whose plane access is a fatal JNI abort). */
    private val bufferOutput: Boolean = false,
    /** Wireless sessions use a tighter stale-output gate and a fixed 60 Hz
     *  operating-rate target. USB is provisioned for the maximum stream rate. */
    private val wireless: Boolean = false,
    private val targetFrameRate: Int? = null,
) {
    @Volatile private var decoder: MediaCodec? = null

    // Written by the constructing thread and read by a release() from any
    // thread; without volatile a racing release can miss the write and leak a
    // MediaCodec plus a hardware decoder instance.
    @Volatile private var initializingCodec: MediaCodec? = null
    private var decoderThread: HandlerThread? = null
    private var decoderHandler: Handler? = null

    private var frameCount = 0L
    private var droppedFrames = 0L
    private var staleOutputDrops = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private var inputFrameCount = 0L
    private var outputFrameCount = 0L

    // A MediaCodec input buffer can be returned just after the socket thread
    // checks the queue. Treating that normal hand-off race as frame loss is
    // especially destructive for HEVC: one discarded P-frame invalidates the
    // reference chain and the forced IDR used to recover creates another large
    // decode burst. Wait for at most three 120-Hz frame periods instead. The wait
    // also provides bounded backpressure to the socket when a producer burst
    // briefly outruns the hardware decoder.
    private var inputBufferWaitCount = 0L
    private var inputBufferWaitSumNs = 0L
    private var inputBufferWaitMaxNs = 0L
    private var inputBufferWaitTimeouts = 0L

    // Decoder pipeline latency (input enqueue -> output buffer available),
    // accumulated over ~60 frames then logged. High values indicate the codec
    // is queuing frames internally (compose/present can't keep up downstream),
    // which surfaces to the user as input lag on the captured display.
    private var latencySumNs: Long = 0
    private var latencySamples: Int = 0
    private var latencyMaxNs: Long = 0

    private val frameTimes = ArrayDeque<Long>(120)

    // Provision the decoder for the rate the host can send, not whatever
    // variable-refresh mode the panel happened to be in when this object was
    // created: the power policy may be holding the panel at 60 Hz while a USB
    // stream still carries 120 FPS, and every frame has to be decoded to keep
    // the reference chain intact. The configure ladder falls back cleanly if a
    // codec rejects the operating-rate hint.
    private val decoderTargetRate =
        (targetFrameRate?.toFloat() ?: DisplayRefreshPolicy.STREAM_INTENT_HZ).coerceAtLeast(30f)
    private val panelRefreshRate = display?.refreshRate ?: 60f

    @Volatile private var currentWidth = initialWidth
    @Volatile private var currentHeight = initialHeight

    @Volatile private var isRunning = false

    /**
     * True only after MediaCodec.start() has returned. [isRunning] flips first
     * so no input-buffer callback is lost, but frame callers must not treat the
     * decoder as usable until start() is done: an input buffer cannot be polled
     * before the codec reaches the Executing state, and the resulting "no input
     * buffer" path forces a keyframe request and drops the IDR that is already
     * in flight.
     */
    @Volatile private var codecStarted = false

    @Volatile private var needsKeyframe = true

    /** True only after the codec has started and is published to frame callers. */
    val isReady: Boolean
        get() = isRunning && codecStarted && decoder != null

    /** True when frames arrive as plane-accessible Images instead of Surface output. */
    val bufferOutputMode: Boolean
        get() = bufferOutput

    private var lastKeyframeRequestNs = 0L

    var onFrameRendered: ((Long) -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    var onKeyframeRequired: ((force: Boolean, reason: String) -> Unit)? = null

    // ByteBuffer-mode (CfL) hand-off. The sink consumes the Image on another
    // thread and invokes the returned callback (which releases the output
    // buffer) when done.
    var onDecodedImage: ((android.media.Image, () -> Unit) -> Unit)? = null
    var onImageOutputUnavailable: (() -> Unit)? = null
    private var imageUnavailableSignalled = false

    /** Decoded stream color range: 1 = full, 2 = limited (video swing). */
    var onColorRange: ((Int) -> Unit)? = null
    /** Decoder pipeline latency (avg/max ms over the last ~60 frames). */
    var onDecodeLatency: ((avgMs: Double, maxMs: Double) -> Unit)? = null
    /** Actual decoded stream size + crop (from the codec output format — the TRUE frame
     *  geometry, which can differ from the configured size when the sender's display
     *  message carries logical dims while the SPS carries physical dims). */
    var onDecodedFormat: ((width: Int, height: Int, cropL: Int, cropR: Int, cropT: Int, cropB: Int) -> Unit)? = null

    /** Fired once when the decoder has accepted many frames but never output any —
     *  the black-screen-with-live-stats signature (stream above the device's
     *  decode limit, or an unusable decoder). Counts only frames actually queued
     *  to MediaCodec, so pre-keyframe drops on a slow start can't trigger it. */
    var onDecoderStalled: (() -> Unit)? = null
    private var stallReported = false
    private var queuedInputCount = 0L

    // The callback is asynchronous and can finish after release() starts. Keep
    // the codec generation with every index so a recreated decoder can never
    // consume a stale index from its predecessor.
    private data class InputBufferRef(
        val generation: Long,
        val index: Int,
    )

    // Available input buffers — fed by onInputBufferAvailable callback.
    private val availableInputBuffers = LinkedBlockingQueue<InputBufferRef>()
    @Volatile private var decoderGeneration = 0L

    init {
        setupDecoder()
    }

    /**
     * Reconfigure for a new stream size. Serialized because a resolution
     * change can now arrive from a background dispatcher: two overlapping
     * rebuilds would interleave release() and setupDecoder() on one codec.
     */
    @Synchronized
    fun updateResolution(
        width: Int,
        height: Int,
    ) {
        if (width != currentWidth || height != currentHeight) {
            currentWidth = width
            currentHeight = height
            release()
            setupDecoder()
            requestKeyframe("resolution changed", force = true)
        }
    }

    /** True when the configured size differs — lets callers skip a rebuild
     *  without paying for one on the thread that only wants to ask. */
    fun needsResolutionUpdate(
        width: Int,
        height: Int,
    ): Boolean = width != currentWidth || height != currentHeight

    private fun setupDecoder() {
        val generation = decoderGeneration + 1L
        decoderGeneration = generation
        val thread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY)
        decoderThread = thread
        try {
            thread.start()
            decoderHandler = Handler(thread.looper)

            // Find a decoder that supports our resolution (prefer HW, fallback to SW)
            val decoderName = findBestDecoder(currentWidth, currentHeight)
            diagLog("setupDecoder: ${currentWidth}x$currentHeight, decoder=$decoderName")

            val codec =
                if (decoderName != null) {
                    MediaCodec.createByCodecName(decoderName)
                } else {
                    MediaCodec.createDecoderByType(mime)
                }
            initializingCodec = codec

            val callback =
                object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                ) {
                    if (decoderGeneration == generation) {
                        availableInputBuffers.offer(InputBufferRef(generation, index))
                    }
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    handleOutputBuffer(codec, index, info, generation)
                }

                override fun onError(
                    codec: MediaCodec,
                    e: MediaCodec.CodecException,
                ) {
                    if (decoderGeneration != generation || decoder !== codec) return
                    diagLog("Codec error: ${e.diagnosticInfo}")
                    Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(
                    codec: MediaCodec,
                    format: MediaFormat,
                ) {
                    if (decoderGeneration != generation || decoder !== codec) return
                    diagLog("Output format changed: $format")
                    runCatching {
                        val w = format.getInteger(MediaFormat.KEY_WIDTH)
                        val h = format.getInteger(MediaFormat.KEY_HEIGHT)
                        val cl = runCatching { format.getInteger("crop-left") }.getOrDefault(0)
                        val cr = runCatching { format.getInteger("crop-right") }.getOrDefault(0)
                        val ct = runCatching { format.getInteger("crop-top") }.getOrDefault(0)
                        val cb = runCatching { format.getInteger("crop-bottom") }.getOrDefault(0)
                        onDecodedFormat?.invoke(w, h, cl, cr, ct, cb)
                    }
                    // color-range: full (COLOR_RANGE_FULL) or limited/video
                    // swing. The CfL renderer needs it to pick the right
                    // YUV→RGB matrix. KEY_COLOR_RANGE is documented as
                    // OPTIONAL and AOSP's ColorUtils only writes it when the
                    // codec reported a non-zero value, so on the decode path it
                    // can be absent — and the Mac's default capture is limited
                    // range, not full.
                    val range = resolveColorRange(runCatching { format.getInteger(MediaFormat.KEY_COLOR_RANGE) }.getOrNull())
                    diagLog("color-range=$range (${if (range == MediaFormat.COLOR_RANGE_LIMITED) "limited" else "full"})")
                    onColorRange?.invoke(range)
                }
            }
            codec.setCallback(callback, decoderHandler)

        val maxInputSize = maxInputSizeBytes(currentWidth, currentHeight)
        val targetSurface: Surface? = if (bufferOutput) null else surface

        var configured = false

        // Attempt 1: Full low-latency config
        try {
            val format = videoFormat(maxInputSize)
            format.setInteger(CODEC_KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, decoderTargetRate.toInt())
            format.setInteger(CODEC_KEY_MAX_B_FRAMES, 0)
            codec.configure(format, targetSurface, null, 0)
            configured = true
            diagLog(
                "Configured with full low-latency @ ${decoderTargetRate.toInt()}fps" +
                    if (bufferOutput) " (buffer output)" else "",
            )
        } catch (e: Exception) {
            diagLog("Full low-latency config failed: ${e.message}")
            codec.reset()
            codec.setCallback(callback, decoderHandler)
        }

        // Attempt 2: some decoders reject KEY_LOW_LATENCY but still accept an
        // operating-rate hint. Keep the rate provisioning before dropping it.
        if (!configured) {
            try {
                val rateFormat = videoFormat(maxInputSize)
                rateFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
                rateFormat.setInteger(MediaFormat.KEY_OPERATING_RATE, decoderTargetRate.toInt())
                rateFormat.setInteger(CODEC_KEY_MAX_B_FRAMES, 0)
                codec.configure(rateFormat, targetSurface, null, 0)
                configured = true
                diagLog("Configured without low-latency key @ ${decoderTargetRate.toInt()}fps")
            } catch (e: Exception) {
                diagLog("Operating-rate config failed: ${e.message}")
                codec.reset()
                codec.setCallback(callback, decoderHandler)
            }
        }

        // Attempt 3: Without KEY_LOW_LATENCY or an operating rate
        if (!configured) {
            try {
                val basicFormat = videoFormat(maxInputSize)
                basicFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
                basicFormat.setInteger(CODEC_KEY_MAX_B_FRAMES, 0)
                codec.configure(basicFormat, targetSurface, null, 0)
                configured = true
                diagLog("Configured with basic format")
            } catch (e: Exception) {
                diagLog("Basic config failed: ${e.message}")
                codec.reset()
                codec.setCallback(callback, decoderHandler)
            }
        }

        // Attempt 4: Minimal config (resolution + input size)
        if (!configured) {
            try {
                codec.configure(videoFormat(maxInputSize), targetSurface, null, 0)
                diagLog("Configured with minimal format")
            } catch (e: Exception) {
                diagLog("All configure attempts failed: ${e.message}")
                Log.e(TAG, "All configure attempts failed", e)
                codec.release()
                decoderThread?.quitSafely()
                decoderThread = null
                decoderHandler = null
                throw e
            }
        }

            codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            needsKeyframe = true
            // isRunning first so no input-buffer callback is dropped, then
            // start(), and only publish the decoder once the codec is actually
            // executing — isReady gates frame callers on codecStarted.
            isRunning = true
            codec.start()
            codecStarted = true
            initializingCodec = null
            decoder = codec
            diagLog(
                "Decoder started: ${currentWidth}x$currentHeight, target=${decoderTargetRate.toInt()}fps " +
                    "panel=${"%.1f".format(panelRefreshRate)}Hz, " +
                    "maxInputSize=$maxInputSize, wireless=$wireless, " +
                    "surface=$surface, valid=${surface.isValid}",
            )
        } catch (failure: Throwable) {
            isRunning = false
            codecStarted = false
            decoderGeneration += 1L
            availableInputBuffers.clear()
            val codec = decoder ?: initializingCodec
            decoder = null
            initializingCodec = null
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            thread.quitSafely()
            if (decoderThread === thread) {
                decoderThread = null
                decoderHandler = null
            }
            throw failure
        }
    }

    /**
     * MediaFormat for this decoder. KEY_MAX_INPUT_SIZE is the key a decoder
     * sizes getInputBuffer() from; without it the input buffers are sized for
     * an AVERAGE frame, and a full IDR (the host allows frames up to 5 MB at
     * 60 Mbps) throws BufferOverflowException, which triggers a keyframe
     * request that overflows again — a live-lock. It must therefore be on
     * every variant, including the reduced ones.
     */
    private fun videoFormat(maxInputSize: Int): MediaFormat =
        MediaFormat
            .createVideoFormat(mime, currentWidth, currentHeight)
            .also { it.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxInputSize) }

    /**
     * Find the best decoder for [mime] at the given resolution and target rate;
     * see [CodecCapabilities.bestDecoderName] for the ranking. Returns a codec
     * name for MediaCodec.createByCodecName(), or null for the default.
     */
    private fun findBestDecoder(
        width: Int,
        height: Int,
    ): String? {
        val chosen =
            runCatching {
                CodecCapabilities.bestDecoderName(mime, width, height, decoderTargetRate)
            }.getOrElse { error ->
                diagLog("Decoder search failed: ${error.message}")
                null
            }
        diagLog(
            if (chosen != null) {
                "Selected decoder: $chosen for ${width}x$height @${decoderTargetRate.toInt()}fps"
            } else {
                "No decoder advertises ${width}x$height — will use default"
            },
        )
        return chosen
    }

    fun decode(
        frameData: ByteArray,
        frameSize: Int = frameData.size,
        frameTimestamp: Long = System.nanoTime(),
        isKeyframe: Boolean = false,
    ) {
        if (!isRunning) {
            diagLog("decode called but isRunning=false")
            onFrameDecoded?.invoke(frameData)
            return
        }

        inputFrameCount++
        if (inputFrameCount == 1L) {
            val header =
                frameData
                    .take(minOf(16, frameSize))
                    .joinToString(" ") { String.format("%02x", it) }
            diagLog(
                "First frame: size=$frameSize, header=[$header], " +
                    "keyframe=$isKeyframe, surface=$surface, valid=${surface.isValid}",
            )
        }
        if (inputFrameCount % 60L == 0L) {
            diagLog(
                "Decode stats: input=$inputFrameCount, output=$outputFrameCount, " +
                    "dropped=$droppedFrames, availBufs=${availableInputBuffers.size}",
            )
        }
        val codec =
            decoder ?: run {
                diagLog("decoder is null in decode()")
                onFrameDecoded?.invoke(frameData)
                return
            }

        if (needsKeyframe && !isKeyframe) {
            dropFrame(
                frameData,
                isKeyframe,
                "waiting for keyframe",
                waitForKeyframe = true,
            )
            return
        }

        // Fast path is still non-blocking. Only wait when the callback hand-off
        // queue is momentarily empty, and never for longer than one 60-Hz frame.
        val generation = decoderGeneration
        val waitStartedNs = System.nanoTime()
        var index = pollInputBuffer(generation)
        if (index == null) {
            val waitedNs = System.nanoTime() - waitStartedNs
            inputBufferWaitCount++
            inputBufferWaitSumNs += waitedNs
            if (waitedNs > inputBufferWaitMaxNs) inputBufferWaitMaxNs = waitedNs
        }
        if (index == null) {
            // This is genuine decoder pressure, not the callback race above.
            // Do not feed later P-frames against a missing reference: that is
            // the visible cursor tear/glitch. Pause until the requested IDR.
            droppedFrames++
            inputBufferWaitTimeouts++
            needsKeyframe = true
            if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
                diagLog(
                    "Dropping frame (no input buffer after ${INPUT_BUFFER_WAIT_MS}ms, " +
                        "dropped=$droppedFrames, timeouts=$inputBufferWaitTimeouts)",
                )
            }
            requestKeyframe("no input buffer", force = true)
            onFrameDecoded?.invoke(frameData)
            return
        }

        queueFrame(codec, index, frameData, frameSize, frameTimestamp, isKeyframe)
    }

    /**
     * Wait for an input buffer from this decoder generation only. Old
     * MediaCodec callbacks may still enqueue after release(), so silently
     * discard those references while preserving the bounded wait budget.
     */
    private fun pollInputBuffer(generation: Long): Int? {
        val deadlineNs = System.nanoTime() + INPUT_BUFFER_WAIT_MS * 1_000_000L
        while (isRunning && decoderGeneration == generation) {
            val ref =
                availableInputBuffers.poll()
                    ?: run {
                        val remainingNs = deadlineNs - System.nanoTime()
                        if (remainingNs <= 0L) return null
                        try {
                            availableInputBuffers.poll(remainingNs, TimeUnit.NANOSECONDS)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            return null
                        }
                    }
                    ?: return null
            if (ref.generation == generation && decoderGeneration == generation) {
                return ref.index
            }
        }
        return null
    }

    private fun queueFrame(
        codec: MediaCodec,
        index: Int,
        frameData: ByteArray,
        frameSize: Int,
        frameTimestamp: Long,
        isKeyframe: Boolean,
    ) {
        try {
            val inputBuffer =
                codec.getInputBuffer(index)
                    ?: throw IllegalStateException("Input buffer $index is null")
            // A frame larger than the configured input buffer would throw
            // BufferOverflowException on the copy below, whose recovery path
            // requests another keyframe that overflows too. Report the real
            // cause instead of looping on it.
            if (frameSize < 0 || frameSize > inputBuffer.capacity()) {
                diagLog(
                    "Frame exceeds the codec input buffer: frame=$frameSize " +
                        "capacity=${inputBuffer.capacity()} ${currentWidth}x$currentHeight",
                )
                needsKeyframe = true
                requestKeyframe("frame exceeds input buffer", force = true)
                return
            }
            inputBuffer.clear()
            inputBuffer.put(frameData, 0, frameSize)
            codec.queueInputBuffer(index, 0, frameSize, frameTimestamp / 1000, 0)
            queuedInputCount++
            if (queuedInputCount == STALL_DETECT_INPUT_FRAMES && outputFrameCount == 0L && !stallReported) {
                stallReported = true
                diagLog("Decoder stalled: $queuedInputCount frames queued, none out")
                onDecoderStalled?.invoke()
            }
            if (isKeyframe) {
                needsKeyframe = false
            }
        } catch (e: Exception) {
            needsKeyframe = true
            requestKeyframe("queue input failed")
            Log.e(TAG, "decode direct feed error", e)
        } finally {
            onFrameDecoded?.invoke(frameData)
        }
    }

    private fun dropFrame(
        frameData: ByteArray,
        isKeyframe: Boolean,
        reason: String,
        waitForKeyframe: Boolean,
        requestRefresh: Boolean = waitForKeyframe,
    ) {
        droppedFrames++
        if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
            diagLog("Dropping frame ($reason, keyframe=$isKeyframe, dropped=$droppedFrames)")
        }
        if (waitForKeyframe) {
            needsKeyframe = true
        }
        if (requestRefresh) {
            requestKeyframe(reason)
        }
        onFrameDecoded?.invoke(frameData)
    }

    private fun requestKeyframe(
        reason: String,
        force: Boolean = false,
    ) {
        val now = System.nanoTime()
        val interval =
            if (force) FORCE_KEYFRAME_REQUEST_INTERVAL_NS else KEYFRAME_REQUEST_INTERVAL_NS
        if (now - lastKeyframeRequestNs < interval) {
            return
        }
        lastKeyframeRequestNs = now
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        onKeyframeRequired?.invoke(force, reason)
    }

    private fun handleOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
        generation: Long,
    ) {
        if (generation != decoderGeneration || !isRunning || decoder !== codec) {
            runCatching { codec.releaseOutputBuffer(index, false) }
            return
        }
        try {
            outputFrameCount++
            val isFirstOutput = outputFrameCount == 1L
            if (isFirstOutput) {
                diagLog("First output frame! size=${info.size}, flags=${info.flags}")
            }

            // Decoder PTS is the Android receive timestamp encoded when the
            // frame entered MediaCodec. Releasing an old output without
            // rendering it keeps the codec reference chain intact while
            // preventing Wi-Fi jitter from becoming visible input lag.
            val nowNs = System.nanoTime()
            val latencyNs = nowNs - info.presentationTimeUs * 1000L
            val hasValidLatency = latencyNs in 0..MAX_REASONABLE_LATENCY_NS
            // Over budget always means drop on wireless, including when the
            // latency is too large to interpret at all. The decision lives in
            // WirelessFreshnessPolicy so it is covered by tests; inlining it
            // here is what let a `!hasValidLatency` escape hatch ship, which
            // rendered exactly the frames the policy exists to drop.
            val shouldRender =
                WirelessFreshnessPolicy.shouldRenderOutput(
                    decodedLatencyNs = latencyNs,
                    hasValidLatency = hasValidLatency,
                    isFirstOutput = isFirstOutput,
                    wireless = wireless,
                    maxReasonableLatencyNs = MAX_REASONABLE_LATENCY_NS,
                    maxRenderLatencyNs = MAX_RENDER_LATENCY_NS,
                )

            if (!shouldRender) {
                droppedFrames++
                staleOutputDrops++
                if (staleOutputDrops <= 3L || staleOutputDrops % 60L == 0L) {
                    diagLog(
                        "Dropping stale output frame: latency=${"%.1f".format(latencyNs / 1_000_000.0)}ms, " +
                            "wireless=$wireless, staleDrops=$staleOutputDrops",
                    )
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
            }

            // ByteBuffer mode (CfL): hand the plane-accessible Image to the
            // renderer; it releases the buffer from its render thread via
            // the consumed callback.
            if (bufferOutput) {
                val sink = onDecodedImage
                val img =
                    try {
                        if (info.size > 0) codec.getOutputImage(index) else null
                    } catch (e: Exception) {
                        diagLog("getOutputImage failed: ${e.message}")
                        null
                    }
                if (sink != null && img != null) {
                    sink(img) {
                        try {
                            codec.releaseOutputBuffer(index, false)
                        } catch (_: Exception) {
                        }
                        updateStats()
                    }
                    return
                }
                if (img == null && !imageUnavailableSignalled) {
                    imageUnavailableSignalled = true
                    diagLog("getOutputImage unavailable — buffer-output CfL cannot run")
                    onImageOutputUnavailable?.invoke()
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
            }

            // Decoder latency: time from queueInputBuffer (where we encoded
            // System.nanoTime()/1000 as PTS) to now. Captures how long the
            // frame spent inside the codec's input/reorder/output queues.
            if (hasValidLatency) {
                latencySumNs += latencyNs
                latencySamples++
                if (latencyNs > latencyMaxNs) latencyMaxNs = latencyNs
            }

            if (outputFrameCount % 60L == 0L) {
                val avgMs = if (latencySamples > 0) latencySumNs / latencySamples / 1_000_000.0 else 0.0
                val maxMs = latencyMaxNs / 1_000_000.0
                val inputWaitAvgMs =
                    if (inputBufferWaitCount > 0) {
                        inputBufferWaitSumNs / inputBufferWaitCount / 1_000_000.0
                    } else {
                        0.0
                    }
                val inputWaitMaxMs = inputBufferWaitMaxNs / 1_000_000.0
                val inBufs = availableInputBuffers.size
                diagLog(
                    "Output #$outputFrameCount: decoder latency avg=${"%.1f".format(avgMs)}ms " +
                        "max=${"%.1f".format(maxMs)}ms over $latencySamples samples, " +
                        "input bufs avail=$inBufs, dropped=$droppedFrames, " +
                        "inputWait avg=${"%.2f".format(inputWaitAvgMs)}ms " +
                        "max=${"%.2f".format(inputWaitMaxMs)}ms timeouts=$inputBufferWaitTimeouts",
                )
                onDecodeLatency?.invoke(avgMs, maxMs)
                latencySumNs = 0
                latencySamples = 0
                latencyMaxNs = 0
                inputBufferWaitCount = 0
                inputBufferWaitSumNs = 0
                inputBufferWaitMaxNs = 0
                inputBufferWaitTimeouts = 0
            }

            codec.releaseOutputBuffer(index, true)
            trackFrameTiming(System.nanoTime())
            updateStats()
        } catch (e: Exception) {
            Log.e(TAG, "releaseOutputBuffer failed", e)
            try {
                codec.releaseOutputBuffer(index, false)
            } catch (_: Exception) {
            }
        }
    }

    private fun trackFrameTiming(timestamp: Long) {
        frameTimes.addLast(timestamp)
        if (frameTimes.size > 120) frameTimes.removeFirst()

        if (frameTimes.size >= 60 && frameCount % 60L == 0L) {
            val deltas = frameTimes.zipWithNext { a, b -> (b - a) / 1_000_000.0 }
            if (deltas.isNotEmpty()) {
                val avgDelta = deltas.average()
                val variance = deltas.map { (it - avgDelta) * (it - avgDelta) }.average()
                val stdDev = kotlin.math.sqrt(variance)
                onFrameStats?.invoke(1000.0 / avgDelta, stdDev)
            }
        }
        onFrameRendered?.invoke(timestamp)
    }

    private fun updateStats() {
        frameCount++
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime
        if (elapsed >= 1000) {
            frameCount = 0
            droppedFrames = 0
            staleOutputDrops = 0
            lastStatsTime = now
        }
    }

    fun release() {
        isRunning = false
        codecStarted = false
        decoderGeneration += 1L
        availableInputBuffers.clear()
        val activeCodec = decoder
        val pendingCodec = initializingCodec
        decoder = null
        initializingCodec = null
        runCatching { activeCodec?.stop() }
        runCatching { activeCodec?.release() }
        if (pendingCodec !== activeCodec) {
            runCatching { pendingCodec?.stop() }
            runCatching { pendingCodec?.release() }
        }
        decoderThread?.quitSafely()
        decoderThread = null
        decoderHandler = null
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val STALL_DETECT_INPUT_FRAMES = 120L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 1_000_000_000L
        private const val FORCE_KEYFRAME_REQUEST_INTERVAL_NS = 200_000_000L
        private const val INPUT_BUFFER_WAIT_MS = 25L
        private const val MAX_RENDER_LATENCY_NS = 100_000_000L
        private const val MAX_REASONABLE_LATENCY_NS = 2_000_000_000L
        private const val MIN_MAX_INPUT_SIZE = 256 * 1024
        private const val MAX_MAX_INPUT_SIZE = 5 * 1024 * 1024

        /**
         * KEY_MAX_INPUT_SIZE for [width] × [height]: one uncompressed 4:2:0
         * frame is the practical ceiling for a single compressed frame, and the
         * host never sends more than 5 MB. Input buffers are allocated from
         * this, so it is deliberately not larger than the host's own frame cap.
         */
        internal fun maxInputSizeBytes(
            width: Int,
            height: Int,
        ): Int {
            if (width <= 0 || height <= 0) return MIN_MAX_INPUT_SIZE
            val rawFrameBytes = width.toLong() * height.toLong() * 3L / 2L
            return rawFrameBytes.coerceIn(MIN_MAX_INPUT_SIZE.toLong(), MAX_MAX_INPUT_SIZE.toLong()).toInt()
        }

        /**
         * MediaFormat.KEY_COLOR_RANGE is OPTIONAL: AOSP's ColorUtils only adds
         * "color-range" to a format when the codec supplied a non-zero value,
         * so a decode-side read can legitimately fail. Absent means the Mac's
         * default capture, which is limited (studio) range.
         */
        internal fun resolveColorRange(raw: Int?): Int =
            if (raw == MediaFormat.COLOR_RANGE_FULL) MediaFormat.COLOR_RANGE_FULL else MediaFormat.COLOR_RANGE_LIMITED
    }
}
