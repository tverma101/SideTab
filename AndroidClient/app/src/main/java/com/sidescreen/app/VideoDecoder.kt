package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaCodecList
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
) {
    private var decoder: MediaCodec? = null
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

    private val frameTimingWindow = FrameTimingWindow()

    private val displayRefreshRate = display?.refreshRate ?: 60f

    private var currentWidth = initialWidth
    private var currentHeight = initialHeight

    @Volatile private var isRunning = false

    @Volatile private var needsKeyframe = true

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

    // Available input buffer indices — fed by onInputBufferAvailable callback
    private val availableInputBuffers = LinkedBlockingQueue<Int>()

    init {
        setupDecoder()
    }

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

    private fun setupDecoder() {
        frameTimingWindow.reset()
        decoderThread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY).also { it.start() }
        decoderHandler = Handler(decoderThread!!.looper)

        // Find a decoder that supports our resolution (prefer HW, fallback to SW)
        val decoderName = findBestDecoder(currentWidth, currentHeight)
        diagLog("setupDecoder: ${currentWidth}x$currentHeight, decoder=$decoderName")

        val codec =
            if (decoderName != null) {
                MediaCodec.createByCodecName(decoderName)
            } else {
                MediaCodec.createDecoderByType(mime)
            }

        val callback =
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                ) {
                    availableInputBuffers.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    handleOutputBuffer(codec, index, info)
                }

                override fun onError(
                    codec: MediaCodec,
                    e: MediaCodec.CodecException,
                ) {
                    diagLog("Codec error: ${e.diagnosticInfo}")
                    Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(
                    codec: MediaCodec,
                    format: MediaFormat,
                ) {
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
                    // color-range: 1 = full, 2 = limited/video (observed on
                    // this decoder: 8-bit SCK capture → 1, 10-bit VideoRange
                    // capture → 2). The CfL renderer needs it to pick the
                    // right YUV→RGB matrix.
                    val range = runCatching { format.getInteger("color-range") }.getOrDefault(1)
                    diagLog("color-range=$range (${if (range == 2) "limited" else "full"})")
                    onColorRange?.invoke(range)
                }
            }
        codec.setCallback(callback, decoderHandler)

        val format =
            MediaFormat.createVideoFormat(
                mime,
                currentWidth,
                currentHeight,
            )

        val targetSurface: Surface? = if (bufferOutput) null else surface

        var configured = false

        // Attempt 1: Full low-latency config
        try {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, displayRefreshRate.toInt())
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            codec.configure(format, targetSurface, null, 0)
            configured = true
            diagLog("Configured with full low-latency${if (bufferOutput) " (buffer output)" else ""}")
        } catch (e: Exception) {
            diagLog("Full low-latency config failed: ${e.message}")
            codec.reset()
            codec.setCallback(callback, decoderHandler)
        }

        // Attempt 2: Without KEY_LOW_LATENCY
        if (!configured) {
            try {
                val basicFormat =
                    MediaFormat.createVideoFormat(
                        mime,
                        currentWidth,
                        currentHeight,
                    )
                basicFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
                basicFormat.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                codec.configure(basicFormat, targetSurface, null, 0)
                configured = true
                diagLog("Configured with basic format")
            } catch (e: Exception) {
                diagLog("Basic config failed: ${e.message}")
                codec.reset()
                codec.setCallback(callback, decoderHandler)
            }
        }

        // Attempt 3: Minimal config (just resolution)
        if (!configured) {
            try {
                val minimalFormat =
                    MediaFormat.createVideoFormat(
                        mime,
                        currentWidth,
                        currentHeight,
                    )
                codec.configure(minimalFormat, targetSurface, null, 0)
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
        isRunning = true
        codec.start()
        decoder = codec
        diagLog(
            "Decoder started: ${currentWidth}x$currentHeight @ ${displayRefreshRate}Hz, " +
                "surface=$surface, valid=${surface.isValid}",
        )
    }

    /**
     * Find the best decoder for [mime] at the given resolution.
     * Prefers hardware decoders, falls back to software if HW can't handle the resolution.
     * Returns codec name to use with MediaCodec.createByCodecName(), or null for default.
     */
    private fun findBestDecoder(
        width: Int,
        height: Int,
    ): String? {
        try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            val targetRate = displayRefreshRate.toDouble().coerceAtLeast(30.0)
            var hwRateDecoder: String? = null
            var hwSizeDecoder: String? = null
            var swRateDecoder: String? = null
            var swSizeDecoder: String? = null

            for (info in codecList.codecInfos) {
                if (info.isEncoder) continue
                val caps =
                    try {
                        info.getCapabilitiesForType(mime)
                    } catch (_: Exception) {
                        continue
                    }

                val videoCaps = caps.videoCapabilities ?: continue
                val isHardware =
                    !info.name.startsWith("c2.android.") &&
                        !info.name.startsWith("OMX.google.")
                val supported = videoCaps.isSizeSupported(width, height)
                val rateSupported =
                    supported &&
                        try {
                            videoCaps.areSizeAndRateSupported(width, height, targetRate)
                        } catch (_: Exception) {
                            false
                        }

                diagLog(
                    "$mime decoder '${info.name}': " +
                        "width=${videoCaps.supportedWidths}, " +
                        "height=${videoCaps.supportedHeights}, " +
                        "hw=$isHardware, supports ${width}x$height=$supported, " +
                        "supports @${"%.0f".format(targetRate)}fps=$rateSupported",
                )

                if (supported) {
                    if (isHardware && rateSupported && hwRateDecoder == null) {
                        hwRateDecoder = info.name
                    } else if (isHardware && hwSizeDecoder == null) {
                        hwSizeDecoder = info.name
                    } else if (!isHardware && rateSupported && swRateDecoder == null) {
                        swRateDecoder = info.name
                    } else if (!isHardware && swSizeDecoder == null) {
                        swSizeDecoder = info.name
                    }
                }
            }

            // Prefer hardware that advertises the target refresh rate, then any
            // hardware decoder for the size, then software as a last resort.
            val chosen = hwRateDecoder ?: hwSizeDecoder ?: swRateDecoder ?: swSizeDecoder
            if (chosen != null) {
                diagLog(
                    "Selected decoder: $chosen " +
                        "(rateSupported=${chosen == hwRateDecoder || chosen == swRateDecoder})",
                )
            } else {
                diagLog("No decoder supports ${width}x$height — will use default")
            }
            return chosen
        } catch (e: Exception) {
            diagLog("Decoder search failed: ${e.message}")
        }
        return null
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
        var index = availableInputBuffers.poll()
        if (index == null) {
            val waitStartedNs = System.nanoTime()
            index =
                try {
                    availableInputBuffers.poll(INPUT_BUFFER_WAIT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    null
                }
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
    ) {
        try {
            outputFrameCount++
            if (outputFrameCount == 1L) {
                diagLog("First output frame! size=${info.size}, flags=${info.flags}")
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
            val nowNs = System.nanoTime()
            val latencyNs = nowNs - info.presentationTimeUs * 1000L
            val hasValidLatency = latencyNs in 0..MAX_REASONABLE_LATENCY_NS
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

            val shouldRender =
                outputFrameCount == 1L ||
                    !hasValidLatency ||
                    latencyNs <= MAX_RENDER_LATENCY_NS

            if (!shouldRender) {
                droppedFrames++
                staleOutputDrops++
                if (staleOutputDrops <= 3L || staleOutputDrops % 60L == 0L) {
                    diagLog(
                        "Dropping stale output frame: latency=${"%.1f".format(latencyNs / 1_000_000.0)}ms, " +
                            "staleDrops=$staleOutputDrops",
                    )
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
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
        if (frameTimingWindow.add(timestamp)) {
            onFrameStats?.invoke(frameTimingWindow.fps, frameTimingWindow.stdDevMs)
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
        frameTimingWindow.reset()
        try {
            availableInputBuffers.clear()
            decoder?.stop()
            decoder?.release()
            decoder = null
            decoderThread?.quitSafely()
            decoderThread = null
            decoderHandler = null
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val STALL_DETECT_INPUT_FRAMES = 120L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 1_000_000_000L
        private const val FORCE_KEYFRAME_REQUEST_INTERVAL_NS = 200_000_000L
        private const val INPUT_BUFFER_WAIT_MS = 25L
        private const val MAX_RENDER_LATENCY_NS = 100_000_000L
        private const val MAX_REASONABLE_LATENCY_NS = 2_000_000_000L
    }
}
