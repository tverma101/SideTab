package com.sidescreen.app

import android.net.Network
import android.os.Process
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Locale
import javax.net.SocketFactory

/**
 * Out-of-band control channel: ping/pong RTT measurement + keyframe requests
 * on a path that never contends with the video stream.
 *
 * TCP-only. Wireless control connections begin with the pairing token; the
 * loopback USB reverse-forward remains unauthenticated because it terminates
 * on the local device. The channel's own connection carries nothing but
 * control/input traffic, so a pong or S Pen event is never queued behind video
 * frames on the main stream.
 *
 * The channel is deliberately self-healing. A video session can survive a
 * control-port restart, Wi-Fi roam, NAT/ARP hiccup, or half-open TCP socket;
 * while control reconnects, callers transparently use the in-band fallback.
 */
class ControlChannel(
    initialHost: String,
    private val port: Int,
    authToken: ByteArray? = null,
    network: Network? = null,
) {
    private val authPreamble = byteArrayOf(0x53, 0x53, 0x57, 0x43) // "SSWC"

    @Volatile
    private var controlAuthToken: ByteArray? = authToken?.clone()

    @Volatile
    private var boundNetwork: Network? = network

    @Volatile
    private var host: String = initialHost

    var onLatencyMeasured: ((Double) -> Unit)? = null

    /** Server→client brightness command: 0..255, apply to the REAL panel. */
    var onBrightnessCommand: ((Int) -> Unit)? = null

    private var socket: Socket? = null
    /** Socket owned by the current connect attempt so disconnect can cancel it. */
    private var pendingSocket: Socket? = null
    private var output: DataOutputStream? = null
    private var connectionGeneration = 0L
    private var loopGeneration = 0L

    @Volatile
    private var tcpActive = false

    @Volatile
    private var running = false

    @Volatile
    private var connecting = false

    @Volatile
    private var sessionGeneration = 0L

    @Volatile
    private var connectionThread: Thread? = null

    private data class ActiveTransport(
        val socket: Socket,
        val output: DataOutputStream,
        val generation: Long,
    )

    private data class OutstandingPing(
        val connectionGeneration: Long,
        val sentAtNs: Long,
    )

    @Volatile
    private var outstandingPing: OutstandingPing? = null

    @Volatile
    private var pingsPaused = false

    /** Offset between the host's uptime clock and this device's monotonic clock. */
    private val clockOffsetEstimator = ClockOffsetEstimator()

    /**
     * Best known host-to-local clock offset in nanoseconds (host clock minus
     * System.nanoTime()), or null until a control pong has been answered.
     */
    val hostClockOffsetNs: Long?
        get() = clockOffsetEstimator.offsetNs

    /** Round trip of the sample the offset came from, or -1 before the first. */
    val hostClockSampleRttMs: Double
        get() = clockOffsetEstimator.sampleRttMs

    private val sendLock = Any()
    private val connectLock = Any()

    // Steady-state control traffic is high-frequency but tiny. These buffers
    // are reused under sendLock so 120 Hz touch/S Pen input does not create a
    // ByteBuffer + ByteArray pair for every packet and wake the GC mid-stroke.
    private val pingPacketScratch = ByteArray(9)
    private val keyframePacketScratch = ByteArray(2)
    private val touchPacketScratch = ByteArray(22)
    private val stylusPacketScratch = ByteArray(StylusProtocol.EVENT_SIZE)

    val isConnected: Boolean
        get() = tcpActive

    fun connect() {
        val thread =
            synchronized(connectLock) {
                if (running) return
                running = true
                loopGeneration += 1L
                val generation = loopGeneration
                Thread({ connectionLoop(generation) }, "ControlConnection")
                    .apply {
                        isDaemon = true
                        priority = Thread.MAX_PRIORITY
                        connectionThread = this
                    }
            }
        thread.start()
    }

    private fun connectionLoop(loopToken: Long) {
        var retryDelayMs = INITIAL_RETRY_MS
        try {
            while (isLoopActive(loopToken)) {
                if (!tcpActive) {
                    if (tryTcp(loopToken)) {
                        retryDelayMs = INITIAL_RETRY_MS
                        continue
                    }
                    if (!isLoopActive(loopToken)) break
                    if (!sleepInterruptibly(retryDelayMs)) {
                        // A route/socket event is actionable new information;
                        // retry immediately instead of finishing an obsolete
                        // exponential-backoff sleep.
                        retryDelayMs = INITIAL_RETRY_MS
                        continue
                    }
                    retryDelayMs = (retryDelayMs * 2).coerceAtMost(MAX_RETRY_MS)
                    continue
                }

                // MainActivity already calls sendPing once per second. This slower
                // safety poll is only a backstop for a ping whose caller disappears
                // before the next tick; 4 wakeups/sec bought no useful latency.
                synchronized(sendLock) {
                    val probe = outstandingPing
                    if (probe != null &&
                        LivenessProbePolicy.isExpired(
                            sentAtNs = probe.sentAtNs,
                            nowNs = System.nanoTime(),
                            timeoutNs = PONG_TIMEOUT_NS,
                            paused = pingsPaused,
                        )
                    ) {
                        val active = activeTransport()
                        if (active != null && active.generation == probe.connectionGeneration) {
                            DiagLog.log("CC", "Control pong timeout — reconnecting")
                            markTcpInactive(active.socket)
                        } else if (active == null || active.generation != probe.connectionGeneration) {
                            outstandingPing = null
                        }
                    }
                }
                if (isLoopActive(loopToken)) sleepInterruptibly(HEALTH_POLL_MS)
            }
        } finally {
            synchronized(connectLock) {
                if (connectionThread === Thread.currentThread()) {
                    connectionThread = null
                }
            }
        }
    }

    /** False means an external event woke the loop before the delay elapsed. */
    private fun sleepInterruptibly(delayMs: Long): Boolean =
        try {
            Thread.sleep(delayMs)
            true
        } catch (_: InterruptedException) {
            // Thread.sleep clears the interrupted flag. Do not restore it here:
            // this interrupt is our intentional wake mechanism, not cancellation.
            false
        }

    private fun wakeConnectionLoop() {
        val thread = connectionThread
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
        }
    }

    private fun isLoopActive(loopToken: Long): Boolean =
        synchronized(connectLock) { running && loopGeneration == loopToken }

    /** One bounded connection attempt. Never holds connectLock across I/O. */
    private fun tryTcp(loopToken: Long): Boolean {
        val (targetNetwork, targetHost) = synchronized(connectLock) {
            if (!running || loopGeneration != loopToken) return false
            if (tcpActive || socket != null || connecting) return tcpActive
            connecting = true
            boundNetwork to host
        }

        // Use the Android Network snapshot captured with the host. Android's
        // per-network SocketFactory is the supported route; keep both the
        // process-default and legacy bindSocket forms as OEM fallbacks so the
        // control channel follows the same recovery path as video.
        val routes: List<Pair<String, () -> Socket>> = buildList {
            if (targetNetwork != null) {
                add("WiFi-factory" to { targetNetwork.socketFactory.createSocket() })
            }
            add("default" to { SocketFactory.getDefault().createSocket() })
            if (targetNetwork != null) {
                add(
                    "WiFi-bind" to {
                        SocketFactory.getDefault().createSocket().also(targetNetwork::bindSocket)
                    },
                )
            }
        }
        var lastError: Exception? = null

        for ((index, route) in routes.withIndex()) {
            if (!isLoopActive(loopToken)) return false
            var s: Socket? = null
            try {
                val candidate = route.second()
                s = candidate
                val registered =
                    synchronized(connectLock) {
                        if (!running || loopGeneration != loopToken ||
                            boundNetwork != targetNetwork || host != targetHost || socket != null ||
                            pendingSocket != null
                        ) {
                            if (loopGeneration == loopToken) connecting = false
                            false
                        } else {
                            pendingSocket = candidate
                            true
                        }
                    }
                if (!registered) {
                    runCatching { candidate.close() }
                    return false
                }
                DiagLog.log("CC", "Control socket using ${route.first} route")
                candidate.tcpNoDelay = true
                candidate.keepAlive = true
                candidate.connect(InetSocketAddress(targetHost, port), CONNECT_TIMEOUT_MS)
                DiagLog.log(
                    "CC",
                    "Control socket connected on ${route.first} " +
                        "from ${candidate.localAddress?.hostAddress}:${candidate.localPort}",
                )
                val controlOutput = DataOutputStream(candidate.getOutputStream())
                writeAuthenticationPreamble(controlOutput)
                candidate.soTimeout = 0

                val installedGeneration =
                    synchronized(connectLock) {
                        if (loopGeneration == loopToken) connecting = false
                        if (!running || loopGeneration != loopToken || this.socket != null ||
                            boundNetwork != targetNetwork || host != targetHost || pendingSocket !== candidate
                        ) {
                            if (boundNetwork != targetNetwork) {
                                DiagLog.log("CC", "Control connect finished on retired Android network — retrying")
                            }
                            if (pendingSocket === candidate) pendingSocket = null
                            null
                        } else {
                            pendingSocket = null
                            connectionGeneration += 1
                            this.socket = candidate
                            output = controlOutput
                            tcpActive = true
                            outstandingPing = null
                            connectionGeneration
                        }
                    }

                if (installedGeneration == null) {
                    try {
                        candidate.close()
                    } catch (_: Exception) {
                    }
                    return false
                }

                DiagLog.log("CC", "Control channel ACTIVE mode=tcp generation=$installedGeneration")
                declareBrightnessSupport()
                declareStylusSupport()
                Thread({ tcpReadLoop(candidate, installedGeneration) }, "ControlTcpThread")
                    .apply {
                        isDaemon = true
                        priority = Thread.MAX_PRIORITY
                    }.start()
                return true
            } catch (e: Exception) {
                lastError = e
                synchronized(connectLock) {
                    if (pendingSocket === s) pendingSocket = null
                    if (loopGeneration == loopToken) connecting = false
                    if (s != null && this.socket === s) {
                        connectionGeneration += 1
                        this.socket = null
                        output = null
                        tcpActive = false
                        outstandingPing = null
                    }
                }
                try {
                    s?.close()
                } catch (_: Exception) {
                }
                DiagLog.log(
                    "CC",
                    "Control TCP ${route.first} route ${index + 1}/${routes.size} failed: " +
                        "${e.javaClass.simpleName}: ${e.message}",
                )
                if (!isLoopActive(loopToken) || boundNetwork != targetNetwork || host != targetHost) return false
            }
        }

        synchronized(connectLock) {
            if (loopGeneration == loopToken) connecting = false
        }
        val error = lastError
        if (error != null) {
            DiagLog.log(
                "CC",
                "Control channel TCP connect failed: " +
                    "${error.javaClass.simpleName}: ${error.message}",
            )
        }
        return false
    }

    private fun tcpReadLoop(
        s: Socket,
        generation: Long,
    ) {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
        } catch (_: Exception) {
        }
        // Reuse the pong payload buffer for the life of this control socket.
        // A control pong is 17 bytes on the wire: [type][clientTs 8][hostSendTs 8].
        // Reading 16 would strand the last host byte in the stream and the next
        // type byte read would be garbage.
        val pongBuffer = ByteArray(CONTROL_PONG_PAYLOAD_BYTES)
        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 4096))
            while (running && isTransportCurrent(s, generation)) {
                val type = input.readByte().toInt()
                val arrival = System.nanoTime()
                when (type) {
                    5 -> {
                        input.readFully(pongBuffer)
                        val clientTs = readLongLE(pongBuffer, 0)
                        val hostSendTs = readLongLE(pongBuffer, 8)
                        val probe = outstandingPing
                        if (probe?.connectionGeneration == generation && probe.sentAtNs == clientTs) {
                            outstandingPing = null
                        }
                        val rtt = (arrival - clientTs) / 1_000_000.0
                        val processedAt = System.nanoTime()
                        val appDelay = (processedAt - arrival) / 1_000_000.0
                        // Host clock read at send time: the only sample of the
                        // Mac's uptime clock on a path this app controls.
                        val offsetNs = clockOffsetEstimator.offer(clientTs, hostSendTs, arrival)
                        DiagLog.log(
                            "CC",
                            String.format(
                                Locale.US,
                                "PONG rtt=%.2fms appDelay=%.3fms transit=%.2fms mode=tcp hostSkewMs=%s",
                                rtt,
                                appDelay,
                                rtt - appDelay,
                                if (offsetNs == null) "n/a" else "%.0f".format(offsetNs / 1e6),
                            ),
                        )
                        onLatencyMeasured?.invoke(rtt)
                    }

                    11 -> {
                        val value = input.readByte().toInt() and 0xFF
                        DiagLog.log("CC", "BRIGHT command value=$value")
                        onBrightnessCommand?.invoke(value)
                    }

                    StylusProtocol.SERVER_SUPPORTS_STYLUS -> {
                        // Acknowledgement of the control-channel stylus advert.
                        // The host need not send it, but an unknown type would
                        // otherwise retire a healthy control socket.
                        DiagLog.log("CC", "HOST STYLUS capability acknowledged")
                    }

                    else -> {
                        DiagLog.log("CC", "Unknown control type $type — reconnecting")
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running && isTransportCurrent(s, generation)) {
                DiagLog.log("CC", "Control read error: ${e.javaClass.simpleName}: ${e.message}")
            }
        } finally {
            markTcpInactive(s)
        }
    }

    fun setAuthToken(token: ByteArray?) {
        controlAuthToken = token?.clone()
    }

    /** Keep the out-of-band channel on the address that accepted video. */
    fun setHost(newHost: String) {
        val previous = host
        if (previous == newHost) return
        host = newHost

        val activeSocket = synchronized(connectLock) {
            val pending = pendingSocket
            pendingSocket = null
            runCatching { pending?.close() }
            socket
        }
        if (activeSocket != null) {
            DiagLog.log("CC", "Video host changed $previous -> $newHost — rebinding control")
            markTcpInactive(activeSocket)
        }
        wakeConnectionLoop()
    }

    /**
     * Rebind immediately when Android gives the video path a different Network
     * handle. Keeping the previous control TCP socket until its ping timeout
     * would lose low-latency input after an otherwise successful Wi-Fi roam.
     */
    fun setNetwork(network: Network?) {
        val previous = boundNetwork
        if (previous == network) return
        boundNetwork = network

        val activeSocket = synchronized(connectLock) {
            val pending = pendingSocket
            pendingSocket = null
            runCatching { pending?.close() }
            socket
        }
        if (activeSocket != null) {
            DiagLog.log("CC", "Android network changed $previous -> $network — rebinding control")
            markTcpInactive(activeSocket)
        }
        // If the channel is between attempts, it may be sleeping in a 5s
        // backoff. A new Android Network makes that wait obsolete.
        wakeConnectionLoop()
    }

    /** Generations advance only; late cleanup cannot move control backward. */
    fun setSessionGeneration(generation: Long) {
        synchronized(sendLock) {
            if (generation > sessionGeneration) {
                sessionGeneration = generation
            }
        }
    }

    private fun writeAuthenticationPreamble(out: DataOutputStream) {
        val token = controlAuthToken ?: return
        require(token.size == 32) { "Control auth token must be 32 bytes" }
        synchronized(sendLock) {
            out.write(authPreamble)
            out.write(token)
            out.flush()
        }
    }

    private fun activeTransport(): ActiveTransport? =
        synchronized(connectLock) {
            val activeSocket = socket ?: return@synchronized null
            val activeOutput = output ?: return@synchronized null
            if (!tcpActive) return@synchronized null
            ActiveTransport(activeSocket, activeOutput, connectionGeneration)
        }

    private fun isTransportCurrent(transport: ActiveTransport): Boolean =
        synchronized(connectLock) {
            tcpActive &&
                socket === transport.socket &&
                output === transport.output &&
                connectionGeneration == transport.generation
        }

    private fun isTransportCurrent(
        expectedSocket: Socket,
        expectedGeneration: Long,
    ): Boolean =
        synchronized(connectLock) {
            tcpActive && socket === expectedSocket && connectionGeneration == expectedGeneration
        }

    private fun declareBrightnessSupport() {
        val transport = activeTransport() ?: return
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return
            try {
                transport.output.write(BRIGHTNESS_CAPABILITY)
                DiagLog.log("CC", "Declared brightness support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Brightness declaration failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
            }
        }
    }

    /**
     * The host learned stylus support from the video socket alone, so every S
     * Pen event that reached this socket was parsed and then dropped. The
     * advert is payload-free, so a host that does not know it skips exactly
     * one byte and the rest of the stream stays aligned.
     */
    private fun declareStylusSupport() {
        val transport = activeTransport() ?: return
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return
            try {
                transport.output.write(STYLUS_CAPABILITY)
                DiagLog.log("CC", "Declared stylus support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Stylus declaration failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
            }
        }
    }

    fun sendPing(): Boolean {
        val transport = activeTransport() ?: return false
        val now = System.nanoTime()
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return false
            // Backgrounding intentionally suspends probe timeouts. Treat the
            // skipped probe as handled so callers do not fall back to the
            // in-band video socket while the Activity is stopped.
            if (pingsPaused) return true

            // Never stack RTT probes. On a congested control socket an older
            // ping is the liveness measurement that matters; adding more only
            // consumes airtime/queue space and makes diagnosis noisier.
            val existing = outstandingPing
            if (existing?.connectionGeneration == transport.generation) {
                if (now - existing.sentAtNs <= PONG_TIMEOUT_NS) {
                    return true
                }
                DiagLog.log("CC", "Control pong timeout detected by ping sender — reconnecting")
                markTcpInactive(transport.socket)
                return false
            }

            return try {
                pingPacketScratch[0] = MESSAGE_PING.toByte()
                putLongLE(pingPacketScratch, 1, now)
                // Arm the deadline only once the ping is actually out. The
                // packet carries the pre-write timestamp so the RTT we get
                // back includes our own drain time, but the expiry clock must
                // start when the bytes left us — otherwise a write that blocks
                // on a full send buffer is mistaken for a lost pong the moment
                // it completes.
                transport.output.write(pingPacketScratch)
                outstandingPing = OutstandingPing(transport.generation, System.nanoTime())
                true
            } catch (e: Exception) {
                outstandingPing = null
                DiagLog.log("CC", "Control ping write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    /** Suspend background probes without closing a healthy control socket. */
    fun setPingsPaused(paused: Boolean) {
        synchronized(sendLock) {
            pingsPaused = paused
            if (paused) outstandingPing = null
        }
    }

    fun requestKeyframe(
        force: Boolean,
        expectedSessionGeneration: Long? = null,
    ): Boolean {
        val transport = activeTransport() ?: return false
        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false
            return try {
                keyframePacketScratch[0] = MESSAGE_KEYFRAME_REQUEST.toByte()
                keyframePacketScratch[1] = if (force) 1 else 0
                transport.output.write(keyframePacketScratch)
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control keyframe write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int,
        x2: Float,
        y2: Float,
        expectedSessionGeneration: Long? = null,
    ): Boolean {
        val transport = activeTransport() ?: return false
        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false

            val count = pointerCount.coerceIn(1, 2)
            touchPacketScratch[0] = MESSAGE_TOUCH.toByte()
            touchPacketScratch[1] = count.toByte()
            putFloatLE(touchPacketScratch, 2, x)
            putFloatLE(touchPacketScratch, 6, y)
            var offset = 10
            if (count == 2) {
                putFloatLE(touchPacketScratch, offset, x2)
                putFloatLE(touchPacketScratch, offset + 4, y2)
                offset += 8
            }
            putIntLE(touchPacketScratch, offset, action)
            val packetSize = 6 + count * 8

            return try {
                transport.output.write(touchPacketScratch, 0, packetSize)
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control touch write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    fun sendStylus(
        event: StylusInputEvent,
        expectedSessionGeneration: Long? = null,
    ): Boolean {
        val transport = activeTransport() ?: return false
        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false
            return try {
                val size = StylusProtocol.encodeInto(event, stylusPacketScratch)
                transport.output.write(stylusPacketScratch, 0, size)
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control stylus write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    private fun markTcpInactive(expectedSocket: Socket) {
        val shouldWake =
            synchronized(connectLock) {
                if (socket !== expectedSocket) return
                connectionGeneration += 1
                tcpActive = false
                output = null
                socket = null
                outstandingPing = null
                try {
                    expectedSocket.close()
                } catch (_: Exception) {
                }
                if (running) {
                    DiagLog.log("CC", "Control channel inactive — reconnecting; in-band fallback active")
                    true
                } else {
                    false
                }
            }
        if (shouldWake) wakeConnectionLoop()
    }

    fun disconnect() {
        val thread =
            synchronized(connectLock) {
                running = false
                loopGeneration += 1L
                connecting = false
                connectionGeneration += 1
                tcpActive = false
                output = null
                outstandingPing = null
                val activeSocket = socket
                socket = null
                val pending = pendingSocket
                pendingSocket = null
                runCatching { pending?.close() }
                try {
                    activeSocket?.close()
                } catch (_: Exception) {
                }
                connectionThread
            }
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
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

    private companion object {
        const val MESSAGE_TOUCH = 2
        const val MESSAGE_PING = 4
        const val MESSAGE_KEYFRAME_REQUEST = 7
        val BRIGHTNESS_CAPABILITY = byteArrayOf(3)
        val STYLUS_CAPABILITY = byteArrayOf(StylusProtocol.CLIENT_SUPPORTS_STYLUS.toByte())

        /** Pong payload after the type byte: [clientTs 8][hostSendTs 8]. */
        const val CONTROL_PONG_PAYLOAD_BYTES = 16

        const val CONNECT_TIMEOUT_MS = 2_000
        const val INITIAL_RETRY_MS = 250L
        const val MAX_RETRY_MS = 5_000L
        const val HEALTH_POLL_MS = 1_000L
        /**
         * Budget for a control-channel pong.
         *
         * This was 4 s, which a control socket sharing a congested Wi-Fi link
         * with the video stream loses routinely: three consecutive 1 Hz pongs
         * can all be delayed by a momentary stall, and the client then closed a
         * perfectly healthy socket. Worse, the resulting `sendPing() == false`
         * used to short-circuit the video probe's "is video flowing?" guard, so
         * a control hiccup armed the video watchdog at 1 Hz regardless of the
         * video path — which is what made the video timeout fire at random.
         *
         * Fifteen seconds is comfortably above real Wi-Fi jitter on a link
         * that is simultaneously carrying video, and still well inside the
         * host's five-minute session deadline and the kernel keepalive floor
         * the Mac now sets, so a genuinely dead control socket is still
         * detected promptly by something.
         */
        const val PONG_TIMEOUT_NS = 15_000_000_000L
    }
}
