package com.sidescreen.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class StreamClient(
    private val host: String,
    private val port: Int,
    private val context: Context? = null,
    controlHost: String = host,
    controlPort: Int = port + 1,
) {
    private var socket: Socket? = null

    @Volatile
    private var pendingSocket: Socket? = null

    @Volatile
    private var connectionAttemptCancelled = false

    private var inputStream: DataInputStream? = null
    private var outputStream: java.io.DataOutputStream? = null

    @Volatile
    private var isConnected = false

    /**
     * Dedicated out-of-band control channel (ping/pong + keyframe/input).
     * It self-heals independently and falls back in-band while unavailable.
     */
    private val controlChannel = ControlChannel(controlHost, controlPort)

    // Callback includes actual frame size (may differ from buffer.size due to pooling),
    // receive timestamp, and whether the frame can restart HEVC decoding.
    var onFrameReceived: ((ByteArray, Int, Long, Boolean) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int, Boolean, Boolean) -> Unit)? = null
    var onStats: ((Double, Double) -> Unit)? = null

    /** Invoked when the server confirms the stream codec (true = HEVC). */
    var onCodecSelected: ((Boolean) -> Unit)? = null

    /** Server→client brightness command (0..255) over the control channel. */
    var onBrightness: ((Int) -> Unit)? = null

    /** Stream codec for sync-frame parsing. HEVC unless the server says otherwise. */
    @Volatile var streamCodecIsHevc = true
        private set

    /** True once a MESSAGE_CODEC_SELECTED arrived — distinguishes new Macs from old. */
    @Volatile var codecNegotiated = false
        private set

    /** True only after the connected Mac explicitly accepts stylus events. */
    @Volatile var stylusSupported = false
        private set

    private var bytesReceived = 0L
    private var framesReceived = 0L
    private var diagFrameCount = 0L
    private var frameCallbackAccumNs = 0L
    private var frameCallbackSamples = 0
    private var lastStatsTime = System.currentTimeMillis()
    private val keyframeRequestLock = Any()
    private var lastKeyframeRequestNs = 0L
    private var lastKeyframeReceivedNs = 0L

    // Buffer pooling to reduce GC pressure from per-frame allocations.
    private val bufferPool = ArrayDeque<ByteArray>(8)
    private val poolLock = Any()

    private fun acquireBuffer(minSize: Int): ByteArray {
        synchronized(poolLock) {
            val iterator = bufferPool.iterator()
            while (iterator.hasNext()) {
                val buffer = iterator.next()
                if (buffer.size >= minSize) {
                    iterator.remove()
                    return buffer
                }
            }
        }
        return ByteArray(minSize)
    }

    fun releaseBuffer(buffer: ByteArray) {
        synchronized(poolLock) {
            if (bufferPool.size < 8) {
                bufferPool.addLast(buffer)
            }
        }
    }

    // High-priority single writer preserves input ordering across touch, S Pen,
    // pings, and keyframe requests without doing network I/O on UI/codec threads.
    private val touchExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                {
                    try {
                        Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
                    } catch (_: Exception) {
                    }
                    runnable.run()
                },
                "TouchThread",
            ).apply {
                priority = Thread.MAX_PRIORITY
            }
        }
    private val touchDispatcher = touchExecutor.asCoroutineDispatcher()
    private val touchScope = CoroutineScope(touchDispatcher)

    /** USB/E3 connection. A dropped session remains terminal for this client. */
    suspend fun connect() =
        withContext(Dispatchers.IO) {
            connectionAttemptCancelled = false
            controlChannel.setAuthToken(null)
            controlChannel.setNetwork(null)
            var announcedConnected = false
            try {
                val s = Socket()
                pendingSocket = s
                s.tcpNoDelay = true
                s.keepAlive = true
                s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                clearPendingSocket(s)
                if (connectionAttemptCancelled) {
                    s.close()
                    return@withContext
                }
                installConnectedSocket(s)
                announcedConnected = true
                diagLog("Connected to $host:$port")
                onConnectionStatus?.invoke(true)
                connectControlChannel()
                receiveData()
            } catch (e: Exception) {
                if (!connectionAttemptCancelled) {
                    Log.e(TAG, "❌ Connection error", e)
                }
            } finally {
                isConnected = false
                cleanupTransport(stopControl = true)
                shutdownTouchExecutor()
                if (announcedConnected && !connectionAttemptCancelled) {
                    onConnectionStatus?.invoke(false)
                } else if (!announcedConnected && !connectionAttemptCancelled) {
                    onConnectionStatus?.invoke(false)
                }
            }
        }

    sealed class WirelessConnectError(msg: String) : Exception(msg) {
        object NetworkUnreachable : WirelessConnectError("Mac unreachable — check both on same WiFi")

        object TokenRejected : WirelessConnectError("Token rejected — re-pair required")

        object ProtocolError : WirelessConnectError("Connection error, please rescan QR")
    }

    /**
     * Wireless connection with session-level recovery.
     *
     * Initial connection failures are reported immediately so pairing errors do
     * not masquerade as retries. After one successful session, ordinary TCP or
     * Wi-Fi loss is retried on the same StreamClient with capped exponential
     * backoff. The input executor is intentionally kept alive across retries.
     * Explicit Disconnect cancels the pending socket and exits immediately.
     */
    suspend fun connectWireless(
        token: ByteArray,
        deviceName: String,
    ) = withContext(Dispatchers.IO) {
        if (token.size != PAIRING_TOKEN_SIZE) {
            throw WirelessConnectError.ProtocolError
        }
        connectionAttemptCancelled = false
        controlChannel.setAuthToken(token)

        var everConnected = false
        var reconnectAttempt = 0
        var terminalError: WirelessConnectError? = null

        try {
            while (!connectionAttemptCancelled) {
                try {
                    openWirelessTransport(token, deviceName)
                    if (connectionAttemptCancelled) break

                    val wasReconnect = everConnected
                    everConnected = true
                    reconnectAttempt = 0
                    isConnected = true
                    diagLog(
                        if (wasReconnect) {
                            "Wireless session recovered to $host:$port"
                        } else {
                            "Wireless connected to $host:$port"
                        },
                    )
                    onConnectionStatus?.invoke(true)
                    connectControlChannel()

                    // Returns only on EOF/unknown protocol or throws on I/O.
                    receiveData()
                    if (!connectionAttemptCancelled) {
                        throw IOException("Wireless stream ended")
                    }
                } catch (e: WirelessConnectError) {
                    cleanupTransport(stopControl = false)
                    isConnected = false
                    if (!everConnected ||
                        e is WirelessConnectError.TokenRejected ||
                        e is WirelessConnectError.ProtocolError
                    ) {
                        throw e
                    }
                    terminalError = e
                } catch (e: IOException) {
                    cleanupTransport(stopControl = false)
                    isConnected = false
                    if (!everConnected) {
                        throw WirelessConnectError.NetworkUnreachable
                    }
                    terminalError = WirelessConnectError.NetworkUnreachable
                    Log.w(TAG, "Wireless stream lost: ${e.javaClass.simpleName}: ${e.message}")
                }

                if (connectionAttemptCancelled) break
                reconnectAttempt += 1
                if (reconnectAttempt > MAX_WIRELESS_RECONNECT_ATTEMPTS) {
                    Log.e(TAG, "Wireless reconnect exhausted after $MAX_WIRELESS_RECONNECT_ATTEMPTS attempts")
                    break
                }
                val delayMs = reconnectDelayMs(reconnectAttempt)
                Log.w(
                    TAG,
                    "Wireless reconnect attempt $reconnectAttempt/$MAX_WIRELESS_RECONNECT_ATTEMPTS in ${delayMs}ms",
                )
                delay(delayMs)
            }
        } finally {
            isConnected = false
            cleanupTransport(stopControl = true)
            shutdownTouchExecutor()
        }

        if (connectionAttemptCancelled) {
            return@withContext
        }

        // Do not transition the UI to idle during recoverable attempts; only
        // report disconnected once recovery is truly exhausted/terminal.
        if (everConnected) {
            onConnectionStatus?.invoke(false)
        }
        throw terminalError ?: WirelessConnectError.NetworkUnreachable
    }

    /** Establish and authenticate one wireless video socket. */
    private fun openWirelessTransport(
        token: ByteArray,
        deviceName: String,
    ) {
        Log.i(TAG, "connectWireless: trying $host:$port (device=$deviceName, token bytes=${token.size})")
        val connectingSocket = Socket()
        pendingSocket = connectingSocket

        val wifiNetwork = selectWifiNetwork()
        controlChannel.setNetwork(wifiNetwork)

        try {
            connectingSocket.tcpNoDelay = true
            connectingSocket.keepAlive = true
            if (wifiNetwork != null) {
                Log.i(TAG, "connectWireless: binding video/control to WiFi network $wifiNetwork")
                wifiNetwork.bindSocket(connectingSocket)
            } else {
                Log.w(TAG, "connectWireless: no WiFi Network handle found, using default routing")
            }
            connectingSocket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        } catch (e: SocketTimeoutException) {
            closePending(connectingSocket)
            Log.e(TAG, "connectWireless: TCP connect timeout to $host:$port")
            throw WirelessConnectError.NetworkUnreachable
        } catch (e: IOException) {
            closePending(connectingSocket)
            Log.e(TAG, "connectWireless: TCP connect failed: ${e.javaClass.simpleName}: ${e.message}")
            throw WirelessConnectError.NetworkUnreachable
        }

        if (connectionAttemptCancelled) {
            closePending(connectingSocket)
            return
        }

        connectingSocket.soTimeout = HANDSHAKE_TIMEOUT_MS
        val request =
            try {
                AuthHandshake.encodeRequest(token, deviceName)
            } catch (_: IllegalArgumentException) {
                closePending(connectingSocket)
                throw WirelessConnectError.ProtocolError
            }

        try {
            connectingSocket.getOutputStream().write(request)
            connectingSocket.getOutputStream().flush()
        } catch (_: IOException) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
        }

        val responseBuf = ByteArray(AUTH_RESPONSE_SIZE)
        var read = 0
        try {
            while (read < responseBuf.size) {
                val count = connectingSocket.getInputStream().read(responseBuf, read, responseBuf.size - read)
                if (count <= 0) break
                read += count
            }
        } catch (e: SocketTimeoutException) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
        } catch (_: IOException) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
        }

        if (connectionAttemptCancelled) {
            closePending(connectingSocket)
            return
        }
        if (read != responseBuf.size) {
            closePending(connectingSocket)
            throw WirelessConnectError.ProtocolError
        }

        val status = AuthHandshake.parseResponse(responseBuf) ?: run {
            closePending(connectingSocket)
            throw WirelessConnectError.ProtocolError
        }
        Log.i(TAG, "connectWireless: handshake response status=$status")

        when (status) {
            AuthHandshake.ResponseStatus.OK -> {
                connectingSocket.soTimeout = 0
                clearPendingSocket(connectingSocket)
                installConnectedSocket(connectingSocket)
            }

            AuthHandshake.ResponseStatus.INVALID_TOKEN -> {
                closePending(connectingSocket)
                throw WirelessConnectError.TokenRejected
            }

            else -> {
                closePending(connectingSocket)
                throw WirelessConnectError.ProtocolError
            }
        }
    }

    /**
     * Prefer the active Wi-Fi network, but do not require INTERNET/VALIDATED.
     * SideScreen is a LAN app and must work on local-only Wi-Fi, travel-router,
     * hotspot, and captive-portal networks where Internet capability is absent.
     */
    private fun selectWifiNetwork(): Network? {
        val ctx = context ?: return null
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        cm.activeNetwork?.let { active ->
            val caps = cm.getNetworkCapabilities(active)
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                return active
            }
        }
        return cm.allNetworks.firstOrNull { network ->
            cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    private fun installConnectedSocket(s: Socket) {
        socket = s
        inputStream = DataInputStream(java.io.BufferedInputStream(s.getInputStream(), 65536))
        outputStream = java.io.DataOutputStream(s.getOutputStream())
        streamCodecIsHevc = true
        codecNegotiated = false
        stylusSupported = false
        lastKeyframeReceivedNs = 0L
        synchronized(keyframeRequestLock) {
            lastKeyframeRequestNs = 0L
        }
        bytesReceived = 0L
        framesReceived = 0L
        lastStatsTime = System.currentTimeMillis()

        // MUST precede type 8: type 8 can trigger the server's early protocol finish.
        advertiseAvcOnlyIfNeeded()
        advertiseDecoderLimits()
        advertiseStylusSupport()
        advertiseFrameMetadataSupport()
        isConnected = true
    }

    private fun clearPendingSocket(expected: Socket) {
        if (pendingSocket === expected) pendingSocket = null
    }

    private fun closePending(expected: Socket) {
        clearPendingSocket(expected)
        try {
            expected.close()
        } catch (_: IOException) {
        }
    }

    /** Start the self-healing out-of-band channel after video authentication. */
    private fun connectControlChannel() {
        controlChannel.onLatencyMeasured = { rttMs ->
            onLatencyMeasured?.invoke(rttMs)
        }
        controlChannel.onBrightnessCommand = { v ->
            onBrightness?.invoke(v)
        }
        controlChannel.connect()
    }

    private fun advertiseFrameMetadataSupport() {
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA)
            out.flush()
            diagLog("Advertised frame metadata support")
        }
    }

    private fun advertiseStylusSupport() {
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_SUPPORTS_STYLUS)
            out.flush()
            diagLog("Advertised S Pen stylus support")
        }
    }

    private fun advertiseAvcOnlyIfNeeded() {
        if (CodecCapabilities.hasHevcDecoder) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_AVC_ONLY)
            out.flush()
            diagLog("Advertised AVC-only (no HEVC decoder on this device)")
        }
    }

    private fun advertiseDecoderLimits() {
        val (maxW, maxH) = CodecCapabilities.maxDecodeSize(CodecCapabilities.streamMime) ?: return
        val w = maxW.coerceAtMost(16383)
        val h = maxH.coerceAtMost(16383)
        if (w < 256 || h < 256) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_DECODER_LIMITS)
            // 7 data bits per byte with the high bit always set: an old Mac
            // skips unknown types one byte at a time, so payload bytes must
            // never collide with real message-type values.
            out.writeByte(0x80 or ((w shr 7) and 0x7F))
            out.writeByte(0x80 or (w and 0x7F))
            out.writeByte(0x80 or ((h shr 7) and 0x7F))
            out.writeByte(0x80 or (h and 0x7F))
            out.flush()
            diagLog("Advertised decoder limit ${w}x$h for ${CodecCapabilities.streamMime}")
        }
    }

    /** Receive until disconnect/EOF. I/O failures bubble to the session owner. */
    private suspend fun receiveData() =
        withContext(Dispatchers.IO) {
            val input = inputStream ?: throw IOException("Missing stream input")

            while (isConnected && !connectionAttemptCancelled) {
                val type = input.readByte()

                when (type.toInt()) {
                    MESSAGE_VIDEO_FRAME -> receiveVideoFrame(input, hasMetadata = false)
                    MESSAGE_VIDEO_FRAME_WITH_METADATA -> receiveVideoFrame(input, hasMetadata = true)

                    1 -> {
                        val width = input.readInt()
                        val height = input.readInt()
                        val transform = input.readInt()
                        val rotation = transform % 1000
                        val flags = transform / 1000
                        val flipHorizontal = flags and 1 == 1
                        val flipVertical = flags and 2 == 2
                        diagLog("Display config: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
                        onDisplaySize?.invoke(width, height, rotation, flipHorizontal, flipVertical)
                    }

                    5 -> {
                        val buf = ByteArray(8)
                        input.readFully(buf)
                        val sentTime = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN).long
                        val rtt = (System.nanoTime() - sentTime) / 1_000_000.0
                        diagLog(String.format("PONG rtt=%.2fms", rtt))
                        onLatencyMeasured?.invoke(rtt)
                    }

                    MESSAGE_CODEC_SELECTED -> {
                        val codecId = input.readByte().toInt()
                        streamCodecIsHevc = codecId == 0
                        codecNegotiated = true
                        diagLog("Server selected codec: ${if (streamCodecIsHevc) "HEVC" else "H.264"}")
                        onCodecSelected?.invoke(streamCodecIsHevc)
                    }

                    MESSAGE_SERVER_SUPPORTS_STYLUS -> {
                        stylusSupported = true
                        diagLog("Mac host accepted S Pen stylus events")
                    }

                    else -> {
                        throw IOException(
                            "Unknown message type ${type.toInt()}; stream may be misaligned",
                        )
                    }
                }
            }
        }

    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int = 1,
        x2: Float = 0f,
        y2: Float = 0f,
    ) {
        if (!isConnected || touchExecutor.isShutdown) return

        touchScope.launch {
            if (controlChannel.sendTouch(x, y, action, pointerCount, x2, y2)) {
                return@launch
            }
            try {
                socket?.getOutputStream()?.let { out ->
                    val count = pointerCount.coerceIn(1, 2)
                    val size = 6 + count * 8
                    val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
                    buffer.put(2.toByte())
                    buffer.put(count.toByte())
                    buffer.putFloat(x)
                    buffer.putFloat(y)
                    if (count == 2) {
                        buffer.putFloat(x2)
                        buffer.putFloat(y2)
                    }
                    buffer.putInt(action)
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    /** Send a direct S Pen event when the Mac host negotiated the extension. */
    fun sendStylus(event: StylusInputEvent) {
        if (!isConnected || !stylusSupported || touchExecutor.isShutdown) return

        touchScope.launch {
            if (controlChannel.sendStylus(event)) {
                return@launch
            }
            try {
                socket?.getOutputStream()?.let { out ->
                    out.write(StylusProtocol.encode(event))
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    var onLatencyMeasured: ((Double) -> Unit)? = null

    fun requestKeyframe(
        force: Boolean = false,
        reason: String = "client request",
    ) {
        if (!isConnected || touchExecutor.isShutdown) return
        val now = System.nanoTime()
        val shouldSend =
            synchronized(keyframeRequestLock) {
                if (!force &&
                    lastKeyframeRequestNs > 0L &&
                    now - lastKeyframeRequestNs < KEYFRAME_REQUEST_INTERVAL_NS
                ) {
                    false
                } else {
                    lastKeyframeRequestNs = now
                    true
                }
            }
        if (!shouldSend) return

        val flags = if (force) KEYFRAME_REQUEST_FLAG_FORCE else 0
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        touchScope.launch {
            if (controlChannel.requestKeyframe(force)) {
                return@launch
            }
            try {
                outputStream?.let { out ->
                    out.write(byteArrayOf(MESSAGE_KEYFRAME_REQUEST.toByte(), flags.toByte()))
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    fun sendPing() {
        if (!isConnected || touchExecutor.isShutdown) return
        if (controlChannel.sendPing()) {
            return
        }
        val queuedAt = System.nanoTime()
        touchScope.launch {
            try {
                socket?.getOutputStream()?.let { out ->
                    val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                    val writeTime = System.nanoTime()
                    diagLog(String.format("PING dispatch=%.2fms", (writeTime - queuedAt) / 1e6))
                    buffer.put(4.toByte())
                    buffer.putLong(writeTime)
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun updateStats(bytes: Int) {
        bytesReceived += bytes
        framesReceived++

        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 1000) {
            val mbps = (bytesReceived * 8.0) / (elapsed / 1000.0) / 1_000_000
            val fps = (framesReceived * 1000.0) / elapsed
            onStats?.invoke(fps, mbps)

            bytesReceived = 0
            framesReceived = 0
            lastStatsTime = now
        }
    }

    private fun receiveVideoFrame(
        input: DataInputStream,
        hasMetadata: Boolean,
    ) {
        val frameSize = input.readInt()

        if (frameSize <= 0 || frameSize > MAX_FRAME_SIZE) {
            throw IOException("Invalid frame size: $frameSize")
        }

        var isKeyframe = false
        if (hasMetadata) {
            val flags = input.readUnsignedByte()
            input.readLong() // Host capture timestamp; clocks are not comparable with Android.
            isKeyframe = (flags and FRAME_FLAG_KEYFRAME) != 0
        }

        val frameData = acquireBuffer(frameSize)
        try {
            input.readFully(frameData, 0, frameSize)
        } catch (e: IOException) {
            // A partial frame never reaches the decoder, so return its pooled
            // buffer here instead of leaking one on every reconnect.
            releaseBuffer(frameData)
            throw e
        }

        if (!hasMetadata && !isKeyframe) {
            isKeyframe = isSyncFrame(frameData, frameSize, streamCodecIsHevc)
        }

        val receiveTimestamp = System.nanoTime()
        checkKeyframeFreshness(receiveTimestamp, isKeyframe)
        diagFrameCount++
        if (diagFrameCount == 1L) {
            diagLog(
                "First video frame: size=$frameSize, keyframe=$isKeyframe, " +
                    "metadata=$hasMetadata, callback=${onFrameReceived != null}",
            )
        }
        if (diagFrameCount % 60L == 0L) {
            val avgCallbackMs = if (frameCallbackSamples > 0) frameCallbackAccumNs / 1e6 / frameCallbackSamples else 0.0
            diagLog(
                "Frames received: $diagFrameCount, readLoop callback avg=" +
                    String.format("%.2fms", avgCallbackMs),
            )
            frameCallbackAccumNs = 0
            frameCallbackSamples = 0
        }

        val cbStart = System.nanoTime()
        val callback = onFrameReceived
        if (callback != null) {
            callback.invoke(frameData, frameSize, receiveTimestamp, isKeyframe)
        } else {
            releaseBuffer(frameData)
        }
        frameCallbackAccumNs += System.nanoTime() - cbStart
        frameCallbackSamples++
        updateStats(frameSize)
    }

    private fun checkKeyframeFreshness(
        receiveTimestamp: Long,
        isKeyframe: Boolean,
    ) {
        if (isKeyframe) {
            lastKeyframeReceivedNs = receiveTimestamp
            return
        }

        val lastKeyframeNs = lastKeyframeReceivedNs
        if (lastKeyframeNs <= 0L) return

        val keyframeAgeNs = receiveTimestamp - lastKeyframeNs
        if (keyframeAgeNs > KEYFRAME_STALE_INTERVAL_NS) {
            requestKeyframe(
                reason = "last keyframe ${keyframeAgeNs / 1_000_000L}ms ago",
            )
        }
    }

    /** Explicit/user disconnect: cancel retries and tear down all resources. */
    fun disconnect() {
        connectionAttemptCancelled = true
        isConnected = false
        try {
            pendingSocket?.close()
        } catch (_: Exception) {
        }
        cleanupTransport(stopControl = true)
        shutdownTouchExecutor()
        onConnectionStatus?.invoke(false)
        Log.d(TAG, "Disconnected")
    }

    /** Close only transport state; optionally keep self-healing control alive. */
    private fun cleanupTransport(stopControl: Boolean) {
        val out = outputStream
        val input = inputStream
        val activeSocket = socket
        val pending = pendingSocket
        outputStream = null
        inputStream = null
        socket = null
        pendingSocket = null

        try {
            out?.close()
        } catch (_: Exception) {
        }
        try {
            input?.close()
        } catch (_: Exception) {
        }
        try {
            activeSocket?.close()
        } catch (_: Exception) {
        }
        try {
            pending?.close()
        } catch (_: Exception) {
        }
        if (stopControl) {
            controlChannel.disconnect()
        }
    }

    private fun shutdownTouchExecutor() {
        if (touchExecutor.isShutdown) return
        touchExecutor.shutdown()
        try {
            if (!touchExecutor.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                touchExecutor.shutdownNow()
                touchExecutor.awaitTermination(200, TimeUnit.MILLISECONDS)
            }
        } catch (e: InterruptedException) {
            touchExecutor.shutdownNow()
            Thread.currentThread().interrupt()
        }
    }

    private fun diagLog(msg: String) = DiagLog.log("SC", msg)

    companion object {
        private const val TAG = "StreamClient"
        private const val MAX_FRAME_SIZE = 5 * 1024 * 1024
        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val HANDSHAKE_TIMEOUT_MS = 5_000
        private const val AUTH_RESPONSE_SIZE = 5
        private const val MAX_WIRELESS_RECONNECT_ATTEMPTS = 12
        private const val WIRELESS_RECONNECT_INITIAL_MS = 250L
        private const val WIRELESS_RECONNECT_MAX_MS = 5_000L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 500_000_000L
        private const val KEYFRAME_STALE_INTERVAL_NS = 1_500_000_000L
        private const val MESSAGE_VIDEO_FRAME = 0
        private const val MESSAGE_VIDEO_FRAME_WITH_METADATA = 6
        private const val MESSAGE_KEYFRAME_REQUEST = 7
        private const val MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA = 8
        private const val MESSAGE_CLIENT_AVC_ONLY = 9
        private const val MESSAGE_CODEC_SELECTED = 10
        private const val MESSAGE_CLIENT_DECODER_LIMITS = 11
        private const val MESSAGE_CLIENT_SUPPORTS_STYLUS = StylusProtocol.CLIENT_SUPPORTS_STYLUS
        private const val MESSAGE_SERVER_SUPPORTS_STYLUS = StylusProtocol.SERVER_SUPPORTS_STYLUS
        private const val FRAME_FLAG_KEYFRAME = 1
        private const val KEYFRAME_REQUEST_FLAG_FORCE = 1
        private const val PAIRING_TOKEN_SIZE = 32

        /** Pure reconnect policy for deterministic unit testing. Attempt is 1-based. */
        internal fun reconnectDelayMs(attempt: Int): Long {
            val shift = (attempt - 1).coerceIn(0, 20)
            return (WIRELESS_RECONNECT_INITIAL_MS shl shift).coerceAtMost(WIRELESS_RECONNECT_MAX_MS)
        }

        /**
         * Codec-aware sync-frame (keyframe) detection on the legacy
         * MESSAGE_VIDEO_FRAME path. HEVC: IRAP NAL types 16..21 from
         * (header and 0x7E) shr 1. H.264: IDR slice, (header and 0x1F) == 5.
         */
        internal fun isSyncFrame(
            data: ByteArray,
            size: Int,
            isHevc: Boolean,
        ): Boolean {
            var i = 0
            while (i + 5 < size) {
                var start = -1
                var startCodeLength = 0

                while (i + 3 < size) {
                    if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                        if (data[i + 2] == 1.toByte()) {
                            start = i
                            startCodeLength = 3
                            break
                        }
                        if (i + 3 < size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                            start = i
                            startCodeLength = 4
                            break
                        }
                    }
                    i++
                }

                if (start < 0) return false

                val nalStart = start + startCodeLength
                if (nalStart + 1 >= size) return false

                val header = data[nalStart].toInt()
                val isSync =
                    if (isHevc) {
                        ((header and 0x7E) shr 1) in 16..21
                    } else {
                        (header and 0x1F) == 5
                    }
                if (isSync) {
                    return true
                }

                i = nalStart + 2
            }
            return false
        }
    }
}
