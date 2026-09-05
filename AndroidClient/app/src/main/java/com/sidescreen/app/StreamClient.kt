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
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private fun resolveControlPort(
    context: Context?,
    videoHost: String,
    videoPort: Int,
    requestedControlHost: String,
    requestedControlPort: Int,
): Int {
    val derivedControlPort = videoPort + 1
    if (requestedControlHost != videoHost || requestedControlPort != derivedControlPort) {
        return requestedControlPort
    }

    val paired =
        try {
            context?.let { PairedHostStorage(it).load() }
        } catch (_: Exception) {
            null
        }
    if (paired != null && paired.host == videoHost && paired.port == videoPort) {
        paired.effectiveControlPort()?.let { return it }
    }
    return requestedControlPort
}

class StreamClient(
    private val host: String,
    private val port: Int,
    private val context: Context? = null,
    controlHost: String = host,
    controlPort: Int = port + 1,
) {
    private data class TransportSnapshot(
        val generation: Long,
        val socket: Socket,
        val output: DataOutputStream,
    )

    private data class RetiredTransport(
        val generation: Long,
        val output: DataOutputStream?,
        val input: DataInputStream?,
        val socket: Socket?,
        val pendingSocket: Socket?,
    )

    private data class VideoProbe(
        val generation: Long,
        val sentAtNs: Long,
    )

    private data class TouchWrite(
        val transport: TransportSnapshot,
        val x: Float,
        val y: Float,
        val action: Int,
        val pointerCount: Int,
        val x2: Float,
        val y2: Float,
    )

    private data class StylusWrite(
        val transport: TransportSnapshot,
        val event: StylusInputEvent,
    )

    private val transportLock = Any()
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: DataOutputStream? = null

    /** Every installed/retired video TCP transport gets a different identity. */
    @Volatile
    private var transportGeneration = 0L

    @Volatile
    private var pendingSocket: Socket? = null

    @Volatile
    private var connectionAttemptCancelled = false

    /** True only after the capability preamble for this transport is complete. */
    @Volatile
    private var isConnected = false

    private val effectiveControlPort =
        resolveControlPort(context, host, port, controlHost, controlPort)

    /**
     * Dedicated out-of-band control channel (ping/pong + keyframe/input).
     * It self-heals independently and falls back in-band while unavailable.
     */
    private val controlChannel = ControlChannel(controlHost, effectiveControlPort)

    var onFrameReceived: ((ByteArray, Int, Long, Boolean) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int, Boolean, Boolean) -> Unit)? = null
    var onStats: ((Double, Double) -> Unit)? = null
    var onCodecSelected: ((Boolean) -> Unit)? = null
    var onBrightness: ((Int) -> Unit)? = null
    var onLatencyMeasured: ((Double) -> Unit)? = null

    @Volatile
    var streamCodecIsHevc = true
        private set

    @Volatile
    var codecNegotiated = false
        private set

    @Volatile
    var stylusSupported = false
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

    @Volatile
    private var lastVideoFrameReceivedNs = 0L

    private val videoProbeLock = Any()
    private var videoProbeOutstanding: VideoProbe? = null
    private var lastVideoProbeSentNs = 0L

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

    // High-rate MOVE/HOVER samples are replaceable; boundary events are not.
    // A blocked Wi-Fi write therefore retains at most one future finger move
    // and one future S Pen motion sample instead of queuing stale cursor replay.
    private val touchMoveCoalescer = LatestSampleCoalescer<TouchWrite>()
    private val stylusMotionCoalescer = LatestSampleCoalescer<StylusWrite>()

    // Fallback writes are serialized by touchExecutor. Reuse packet storage so
    // a temporary control-channel outage does not turn 120 Hz input into a GC
    // allocation storm on the video socket.
    private val inBandTouchPacket = ByteArray(22)
    private val inBandStylusPacket = ByteArray(StylusProtocol.EVENT_SIZE)
    private val inBandKeyframePacket = ByteArray(2)
    private val inBandPingPacket = ByteArray(9)

    /** USB/E3 connection. A dropped session remains terminal for this client. */
    suspend fun connect() =
        withContext(Dispatchers.IO) {
            connectionAttemptCancelled = false
            controlChannel.setAuthToken(null)
            controlChannel.setNetwork(null)
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

                val generation = installConnectedSocket(s)
                diagLog("Connected to $host:$port control=$effectiveControlPort generation=$generation")
                onConnectionStatus?.invoke(true)
                connectControlChannel()
                receiveData(generation)
            } catch (e: Exception) {
                if (!connectionAttemptCancelled) {
                    Log.e(TAG, "❌ Connection error", e)
                }
            } finally {
                cleanupTransport(stopControl = true)
                shutdownTouchExecutor()
                if (!connectionAttemptCancelled) {
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
     * Wireless connection with session-level recovery. The first user-requested
     * connect keeps generous timeouts. Once a session has existed, LAN retries
     * are deliberately short: if the cached endpoint is stale, token-bound
     * Bonjour recovery is more useful than repeatedly waiting on the same IP.
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
                    val reconnecting = everConnected
                    val connectTimeout =
                        if (reconnecting) RECONNECT_CONNECT_TIMEOUT_MS else CONNECT_TIMEOUT_MS
                    val handshakeTimeout =
                        if (reconnecting) RECONNECT_HANDSHAKE_TIMEOUT_MS else HANDSHAKE_TIMEOUT_MS
                    val generation =
                        openWirelessTransport(
                            token,
                            deviceName,
                            connectTimeout,
                            handshakeTimeout,
                        )
                    if (connectionAttemptCancelled) break

                    val wasReconnect = everConnected
                    everConnected = true
                    reconnectAttempt = 0
                    diagLog(
                        if (wasReconnect) {
                            "Wireless session recovered to $host:$port control=$effectiveControlPort generation=$generation"
                        } else {
                            "Wireless connected to $host:$port control=$effectiveControlPort generation=$generation"
                        },
                    )
                    onConnectionStatus?.invoke(true)
                    connectControlChannel()

                    receiveData(generation)
                    if (!connectionAttemptCancelled) {
                        throw IOException("Wireless stream ended")
                    }
                } catch (e: WirelessConnectError) {
                    cleanupTransport(stopControl = false)
                    if (!everConnected ||
                        e is WirelessConnectError.TokenRejected ||
                        e is WirelessConnectError.ProtocolError
                    ) {
                        throw e
                    }
                    terminalError = e
                } catch (e: IOException) {
                    cleanupTransport(stopControl = false)
                    if (!everConnected) {
                        throw WirelessConnectError.NetworkUnreachable
                    }
                    terminalError = WirelessConnectError.NetworkUnreachable
                    Log.w(TAG, "Wireless stream lost: ${e.javaClass.simpleName}: ${e.message}")
                }

                if (connectionAttemptCancelled) break
                reconnectAttempt += 1
                if (reconnectAttempt >= MAX_WIRELESS_RECONNECT_ATTEMPTS) {
                    Log.e(TAG, "Wireless reconnect exhausted after $reconnectAttempt attempts")
                    break
                }
                val delayMs = reconnectDelayMs(reconnectAttempt)
                Log.w(
                    TAG,
                    "Wireless reconnect attempt ${reconnectAttempt + 1}/$MAX_WIRELESS_RECONNECT_ATTEMPTS in ${delayMs}ms",
                )
                delay(delayMs)
            }
        } finally {
            cleanupTransport(stopControl = true)
            shutdownTouchExecutor()
        }

        if (connectionAttemptCancelled) {
            return@withContext
        }

        if (everConnected) {
            onConnectionStatus?.invoke(false)
        }
        throw terminalError ?: WirelessConnectError.NetworkUnreachable
    }

    private fun openWirelessTransport(
        token: ByteArray,
        deviceName: String,
        connectTimeoutMs: Int,
        handshakeTimeoutMs: Int,
    ): Long {
        Log.i(
            TAG,
            "connectWireless: trying $host:$port " +
                "(device=$deviceName, connect=${connectTimeoutMs}ms, auth=${handshakeTimeoutMs}ms)",
        )
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
            connectingSocket.connect(InetSocketAddress(host, port), connectTimeoutMs)
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
            throw WirelessConnectError.NetworkUnreachable
        }

        connectingSocket.soTimeout = handshakeTimeoutMs
        val request =
            try {
                AuthHandshake.encodeRequest(token, deviceName)
            } catch (_: IllegalArgumentException) {
                closePending(connectingSocket)
                throw WirelessConnectError.ProtocolError
            }

        try {
            val socketOutput = connectingSocket.getOutputStream()
            socketOutput.write(request)
            socketOutput.flush()
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
        } catch (_: SocketTimeoutException) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
        } catch (_: IOException) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
        }

        if (connectionAttemptCancelled) {
            closePending(connectingSocket)
            throw WirelessConnectError.NetworkUnreachable
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

        return when (status) {
            AuthHandshake.ResponseStatus.OK -> {
                if (connectionAttemptCancelled) {
                    closePending(connectingSocket)
                    throw WirelessConnectError.NetworkUnreachable
                }
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

    /**
     * Two-phase install: publish a new generation as non-writable, send the
     * capability preamble from this thread only, then mark it connected. This
     * prevents the still-running ping/input loop from interleaving bytes with
     * codec/decoder/stylus negotiation during an internal reconnect.
     */
    private fun installConnectedSocket(s: Socket): Long {
        val input = DataInputStream(java.io.BufferedInputStream(s.getInputStream(), 65536))
        val output = DataOutputStream(s.getOutputStream())
        val generation =
            synchronized(transportLock) {
                transportGeneration += 1
                socket = s
                inputStream = input
                outputStream = output
                isConnected = false
                transportGeneration
            }

        controlChannel.setSessionGeneration(generation)
        resetVideoProbeState()

        streamCodecIsHevc = true
        codecNegotiated = false
        stylusSupported = false
        lastKeyframeReceivedNs = 0L
        lastVideoFrameReceivedNs = 0L
        synchronized(keyframeRequestLock) {
            lastKeyframeRequestNs = 0L
        }
        bytesReceived = 0L
        framesReceived = 0L
        lastStatsTime = System.currentTimeMillis()

        advertiseCapabilities(output)

        synchronized(transportLock) {
            if (transportGeneration != generation || socket !== s || connectionAttemptCancelled) {
                throw IOException("Transport retired during protocol startup")
            }
            isConnected = true
        }
        return generation
    }

    private fun advertiseCapabilities(out: DataOutputStream) {
        val packet = ByteArray(8)
        var size = 0

        if (!CodecCapabilities.hasHevcDecoder) {
            packet[size++] = MESSAGE_CLIENT_AVC_ONLY.toByte()
        }

        val decoderLimit = CodecCapabilities.maxDecodeSize(CodecCapabilities.streamMime)
        if (decoderLimit != null) {
            val w = decoderLimit.first.coerceAtMost(16383)
            val h = decoderLimit.second.coerceAtMost(16383)
            if (w >= 256 && h >= 256) {
                packet[size++] = MESSAGE_CLIENT_DECODER_LIMITS.toByte()
                packet[size++] = (0x80 or ((w shr 7) and 0x7F)).toByte()
                packet[size++] = (0x80 or (w and 0x7F)).toByte()
                packet[size++] = (0x80 or ((h shr 7) and 0x7F)).toByte()
                packet[size++] = (0x80 or (h and 0x7F)).toByte()
            }
        }

        packet[size++] = MESSAGE_CLIENT_SUPPORTS_STYLUS.toByte()
        packet[size++] = MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA.toByte()
        out.write(packet, 0, size)
        out.flush()

        diagLog(
            "Advertised capabilities in one write: bytes=$size " +
                "avcOnly=${!CodecCapabilities.hasHevcDecoder}, decoder=${decoderLimit != null}, stylus=true, metadata=true",
        )
    }

    private fun currentTransport(): TransportSnapshot? =
        synchronized(transportLock) {
            if (!isConnected) return@synchronized null
            val activeSocket = socket ?: return@synchronized null
            val activeOutput = outputStream ?: return@synchronized null
            TransportSnapshot(transportGeneration, activeSocket, activeOutput)
        }

    private fun isTransportCurrent(snapshot: TransportSnapshot): Boolean =
        synchronized(transportLock) {
            isConnected &&
                transportGeneration == snapshot.generation &&
                socket === snapshot.socket &&
                outputStream === snapshot.output
        }

    private fun isTransportGenerationCurrent(generation: Long): Boolean =
        synchronized(transportLock) {
            isConnected && transportGeneration == generation
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

    private fun connectControlChannel() {
        controlChannel.onLatencyMeasured = { rttMs -> onLatencyMeasured?.invoke(rttMs) }
        controlChannel.onBrightnessCommand = { value -> onBrightness?.invoke(value) }
        controlChannel.connect()
    }

    private suspend fun receiveData(generation: Long) =
        withContext(Dispatchers.IO) {
            val input =
                synchronized(transportLock) {
                    if (transportGeneration != generation) null else inputStream
                } ?: throw IOException("Missing stream input")
            val pongBuffer = ByteArray(8)

            while (isTransportGenerationCurrent(generation) && !connectionAttemptCancelled) {
                val type = input.readByte()
                when (type.toInt()) {
                    MESSAGE_VIDEO_FRAME -> receiveVideoFrame(input, hasMetadata = false)
                    MESSAGE_VIDEO_FRAME_WITH_METADATA -> receiveVideoFrame(input, hasMetadata = true)

                    MESSAGE_DISPLAY_CONFIG -> {
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

                    MESSAGE_PONG -> {
                        input.readFully(pongBuffer)
                        val sentTime = readLongLE(pongBuffer, 0)
                        val rtt = (System.nanoTime() - sentTime) / 1_000_000.0
                        val matchedProbe =
                            synchronized(videoProbeLock) {
                                val probe = videoProbeOutstanding
                                if (probe?.generation == generation && probe.sentAtNs == sentTime) {
                                    videoProbeOutstanding = null
                                    true
                                } else {
                                    false
                                }
                            }
                        diagLog(String.format("VIDEO PONG rtt=%.2fms matched=%s", rtt, matchedProbe))
                        if (!controlChannel.isConnected) {
                            onLatencyMeasured?.invoke(rtt)
                        }
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

                    else -> throw IOException("Unknown message type ${type.toInt()}; stream may be misaligned")
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
        if (touchExecutor.isShutdown) return
        val transport = currentTransport() ?: return
        val write = TouchWrite(transport, x, y, action, pointerCount, x2, y2)

        if (action == TOUCH_ACTION_MOVE) {
            touchMoveCoalescer.offer(write)?.let { epoch ->
                scheduleTouchMoveDrain(epoch)
            }
            return
        }

        // The boundary packet carries current/final coordinates. Advancing the
        // epoch both discards obsolete motion and makes any already-queued drain
        // unable to consume samples from the next gesture.
        touchMoveCoalescer.advanceBoundary()
        touchScope.launch { sendTouchNow(write) }
    }

    private fun scheduleTouchMoveDrain(epoch: Long) {
        if (touchExecutor.isShutdown) return
        touchScope.launch {
            repeat(COALESCED_INPUT_BURST) {
                val write = touchMoveCoalescer.takeLatest(epoch) ?: return@repeat
                sendTouchNow(write)
            }
            if (touchMoveCoalescer.finishBurst(epoch) && !touchExecutor.isShutdown) {
                scheduleTouchMoveDrain(epoch)
            }
        }
    }

    private fun sendTouchNow(write: TouchWrite) {
        val transport = write.transport
        if (!isTransportCurrent(transport)) return
        if (
            controlChannel.sendTouch(
                write.x,
                write.y,
                write.action,
                write.pointerCount,
                write.x2,
                write.y2,
                expectedSessionGeneration = transport.generation,
            )
        ) {
            return
        }
        if (!isTransportCurrent(transport)) return

        try {
            val count = write.pointerCount.coerceIn(1, 2)
            inBandTouchPacket[0] = MESSAGE_TOUCH.toByte()
            inBandTouchPacket[1] = count.toByte()
            putFloatLE(inBandTouchPacket, 2, write.x)
            putFloatLE(inBandTouchPacket, 6, write.y)
            var offset = 10
            if (count == 2) {
                putFloatLE(inBandTouchPacket, offset, write.x2)
                putFloatLE(inBandTouchPacket, offset + 4, write.y2)
                offset += 8
            }
            putIntLE(inBandTouchPacket, offset, write.action)
            transport.output.write(inBandTouchPacket, 0, 6 + count * 8)
        } catch (e: Exception) {
            failVideoTransport(transport, "in-band touch write failed", e)
        }
    }

    fun sendStylus(event: StylusInputEvent) {
        if (!stylusSupported || touchExecutor.isShutdown) return
        val transport = currentTransport() ?: return
        val write = StylusWrite(transport, event)
        val replaceable =
            event.action == StylusProtocol.ACTION_MOVE ||
                event.action == StylusProtocol.ACTION_HOVER

        if (replaceable) {
            stylusMotionCoalescer.offer(write)?.let { epoch ->
                scheduleStylusMotionDrain(epoch)
            }
            return
        }

        stylusMotionCoalescer.advanceBoundary()
        touchScope.launch { sendStylusNow(write) }
    }

    private fun scheduleStylusMotionDrain(epoch: Long) {
        if (touchExecutor.isShutdown) return
        touchScope.launch {
            repeat(COALESCED_INPUT_BURST) {
                val write = stylusMotionCoalescer.takeLatest(epoch) ?: return@repeat
                sendStylusNow(write)
            }
            if (stylusMotionCoalescer.finishBurst(epoch) && !touchExecutor.isShutdown) {
                scheduleStylusMotionDrain(epoch)
            }
        }
    }

    private fun sendStylusNow(write: StylusWrite) {
        val transport = write.transport
        if (!isTransportCurrent(transport)) return
        if (controlChannel.sendStylus(write.event, expectedSessionGeneration = transport.generation)) {
            return
        }
        if (!isTransportCurrent(transport)) return

        try {
            val size = StylusProtocol.encodeInto(write.event, inBandStylusPacket)
            transport.output.write(inBandStylusPacket, 0, size)
        } catch (e: Exception) {
            failVideoTransport(transport, "in-band stylus write failed", e)
        }
    }

    fun requestKeyframe(
        force: Boolean = false,
        reason: String = "client request",
    ) {
        if (touchExecutor.isShutdown) return
        val transport = currentTransport() ?: return
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
            if (!isTransportCurrent(transport)) return@launch
            if (
                controlChannel.requestKeyframe(
                    force,
                    expectedSessionGeneration = transport.generation,
                )
            ) {
                return@launch
            }
            if (!isTransportCurrent(transport)) return@launch

            try {
                inBandKeyframePacket[0] = MESSAGE_KEYFRAME_REQUEST.toByte()
                inBandKeyframePacket[1] = flags.toByte()
                transport.output.write(inBandKeyframePacket)
            } catch (e: Exception) {
                failVideoTransport(transport, "in-band keyframe request failed", e)
            }
        }
    }

    fun sendPing() {
        if (touchExecutor.isShutdown) return
        val transport = currentTransport() ?: return
        val now = System.nanoTime()

        val outstanding = synchronized(videoProbeLock) { videoProbeOutstanding }
        if (outstanding != null && now - outstanding.sentAtNs > VIDEO_PROBE_TIMEOUT_NS) {
            if (outstanding.generation == transport.generation) {
                failVideoTransport(transport, "video-path ping timed out", null)
                return
            }
            synchronized(videoProbeLock) {
                if (videoProbeOutstanding === outstanding) videoProbeOutstanding = null
            }
        }

        val controlSent = controlChannel.sendPing()
        val lastFrameNs = lastVideoFrameReceivedNs
        val videoRecentlyActive =
            lastFrameNs > 0L && now >= lastFrameNs && now - lastFrameNs < VIDEO_PROBE_INTERVAL_NS
        val shouldProbeVideo =
            synchronized(videoProbeLock) {
                videoProbeOutstanding == null &&
                    (!controlSent ||
                        (!videoRecentlyActive && now - lastVideoProbeSentNs >= VIDEO_PROBE_INTERVAL_NS))
            }
        if (!shouldProbeVideo) return

        val queuedAt = now
        touchScope.launch {
            if (!isTransportCurrent(transport)) return@launch
            val writeTime = System.nanoTime()
            synchronized(videoProbeLock) {
                if (videoProbeOutstanding != null) return@launch
                videoProbeOutstanding = VideoProbe(transport.generation, writeTime)
                lastVideoProbeSentNs = writeTime
            }

            try {
                diagLog(String.format("VIDEO PING dispatch=%.2fms", (writeTime - queuedAt) / 1e6))
                inBandPingPacket[0] = MESSAGE_PING.toByte()
                putLongLE(inBandPingPacket, 1, writeTime)
                transport.output.write(inBandPingPacket)
            } catch (e: Exception) {
                synchronized(videoProbeLock) {
                    val probe = videoProbeOutstanding
                    if (probe?.generation == transport.generation && probe.sentAtNs == writeTime) {
                        videoProbeOutstanding = null
                    }
                }
                failVideoTransport(transport, "video-path ping write failed", e)
            }
        }
    }

    private fun failVideoTransport(
        transport: TransportSnapshot,
        reason: String,
        error: Exception?,
    ) {
        if (!isTransportCurrent(transport)) return
        if (error == null) {
            diagLog("Video transport unhealthy: $reason — forcing reconnect")
        } else {
            diagLog(
                "Video transport unhealthy: $reason " +
                    "(${error.javaClass.simpleName}: ${error.message}) — forcing reconnect",
            )
        }
        try {
            transport.socket.close()
        } catch (_: Exception) {
        }
    }

    private fun resetVideoProbeState() {
        synchronized(videoProbeLock) {
            videoProbeOutstanding = null
            lastVideoProbeSentNs = 0L
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
            input.readLong()
            isKeyframe = (flags and FRAME_FLAG_KEYFRAME) != 0
        }

        val frameData = acquireBuffer(frameSize)
        try {
            input.readFully(frameData, 0, frameSize)
        } catch (e: IOException) {
            releaseBuffer(frameData)
            throw e
        }

        if (!hasMetadata && !isKeyframe) {
            isKeyframe = isSyncFrame(frameData, frameSize, streamCodecIsHevc)
        }

        val receiveTimestamp = System.nanoTime()
        val previousFrameReceivedNs = lastVideoFrameReceivedNs
        lastVideoFrameReceivedNs = receiveTimestamp

        // Receiving actual frame bytes is stronger liveness evidence than a
        // separate video ping. Do not reconnect an actively delivering stream
        // merely because its pong is queued behind video data.
        synchronized(videoProbeLock) {
            videoProbeOutstanding = null
        }

        checkKeyframeFreshness(receiveTimestamp, isKeyframe, previousFrameReceivedNs)
        diagFrameCount++
        if (diagFrameCount == 1L) {
            diagLog(
                "First video frame: size=$frameSize, keyframe=$isKeyframe, " +
                    "metadata=$hasMetadata, callback=${onFrameReceived != null}",
            )
        }
        if (diagFrameCount % 60L == 0L) {
            val avgCallbackMs =
                if (frameCallbackSamples > 0) {
                    frameCallbackAccumNs / 1e6 / frameCallbackSamples
                } else {
                    0.0
                }
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
        previousFrameReceivedNs: Long,
    ) {
        if (isKeyframe) {
            lastKeyframeReceivedNs = receiveTimestamp
            return
        }

        // A long frame-silent interval is expected when the Mac dirty-rect gate
        // suppresses an unchanged desktop. TCP preserved the encoded reference
        // chain; the first frame after that quiet period must not be mistaken for
        // a lost-keyframe condition and trigger an unnecessary large IDR burst.
        if (isLongVideoGap(previousFrameReceivedNs, receiveTimestamp)) {
            lastKeyframeReceivedNs = receiveTimestamp
            return
        }

        val lastKeyframeNs = lastKeyframeReceivedNs
        if (lastKeyframeNs <= 0L) return

        val keyframeAgeNs = receiveTimestamp - lastKeyframeNs
        if (keyframeAgeNs > KEYFRAME_STALE_INTERVAL_NS) {
            requestKeyframe(reason = "last keyframe ${keyframeAgeNs / 1_000_000L}ms ago")
        }
    }

    fun disconnect() {
        connectionAttemptCancelled = true
        try {
            pendingSocket?.close()
        } catch (_: Exception) {
        }
        cleanupTransport(stopControl = true)
        shutdownTouchExecutor()
        onConnectionStatus?.invoke(false)
        Log.d(TAG, "Disconnected")
    }

    private fun cleanupTransport(stopControl: Boolean) {
        // Advance both motion epochs so an already-scheduled drain from the
        // retired socket cannot consume or retain samples from a future session.
        touchMoveCoalescer.advanceBoundary()
        stylusMotionCoalescer.advanceBoundary()

        val retired =
            synchronized(transportLock) {
                transportGeneration += 1
                val generation = transportGeneration
                val state =
                    RetiredTransport(
                        generation = generation,
                        output = outputStream,
                        input = inputStream,
                        socket = socket,
                        pendingSocket = pendingSocket,
                    )
                outputStream = null
                inputStream = null
                socket = null
                pendingSocket = null
                isConnected = false
                state
            }

        controlChannel.setSessionGeneration(retired.generation)
        resetVideoProbeState()

        try {
            retired.output?.close()
        } catch (_: Exception) {
        }
        try {
            retired.input?.close()
        } catch (_: Exception) {
        }
        try {
            retired.socket?.close()
        } catch (_: Exception) {
        }
        try {
            retired.pendingSocket?.close()
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

    private fun putFloatLE(
        target: ByteArray,
        offset: Int,
        value: Float,
    ) = putIntLE(target, offset, value.toRawBits())

    private fun putIntLE(
        target: ByteArray,
        offset: Int,
        value: Int,
    ) {
        target[offset] = value.toByte()
        target[offset + 1] = (value ushr 8).toByte()
        target[offset + 2] = (value ushr 16).toByte()
        target[offset + 3] = (value ushr 24).toByte()
    }

    private fun putLongLE(
        target: ByteArray,
        offset: Int,
        value: Long,
    ) {
        for (i in 0 until 8) {
            target[offset + i] = (value ushr (i * 8)).toByte()
        }
    }

    private fun readLongLE(
        source: ByteArray,
        offset: Int,
    ): Long {
        var value = 0L
        for (i in 0 until 8) {
            value = value or ((source[offset + i].toLong() and 0xFFL) shl (i * 8))
        }
        return value
    }

    private fun diagLog(msg: String) = DiagLog.log("SC", msg)

    companion object {
        private const val TAG = "StreamClient"
        private const val MAX_FRAME_SIZE = 5 * 1024 * 1024
        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val RECONNECT_CONNECT_TIMEOUT_MS = 1_000
        private const val HANDSHAKE_TIMEOUT_MS = 5_000
        private const val RECONNECT_HANDSHAKE_TIMEOUT_MS = 2_000
        private const val AUTH_RESPONSE_SIZE = 5
        private const val MAX_WIRELESS_RECONNECT_ATTEMPTS = 3
        private const val WIRELESS_RECONNECT_INITIAL_MS = 250L
        private const val WIRELESS_RECONNECT_MAX_MS = 5_000L
        private const val VIDEO_PROBE_INTERVAL_NS = 3_000_000_000L
        private const val VIDEO_PROBE_TIMEOUT_NS = 6_000_000_000L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 500_000_000L
        private const val KEYFRAME_STALE_INTERVAL_NS = 1_500_000_000L
        private const val COALESCED_INPUT_BURST = 2
        private const val TOUCH_ACTION_MOVE = 1

        private const val MESSAGE_VIDEO_FRAME = 0
        private const val MESSAGE_DISPLAY_CONFIG = 1
        private const val MESSAGE_TOUCH = 2
        private const val MESSAGE_PING = 4
        private const val MESSAGE_PONG = 5
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

        internal fun reconnectDelayMs(attempt: Int): Long {
            val shift = (attempt - 1).coerceIn(0, 20)
            return (WIRELESS_RECONNECT_INITIAL_MS shl shift).coerceAtMost(WIRELESS_RECONNECT_MAX_MS)
        }

        internal fun isLongVideoGap(
            previousFrameNs: Long,
            currentFrameNs: Long,
        ): Boolean =
            previousFrameNs > 0L &&
                currentFrameNs >= previousFrameNs &&
                currentFrameNs - previousFrameNs > KEYFRAME_STALE_INTERVAL_NS

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
                if (isSync) return true

                i = nalStart + 2
            }
            return false
        }
    }
}
