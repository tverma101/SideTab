package com.sidescreen.app

import android.net.Network
import android.os.Process
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket

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
    private val host: String,
    private val port: Int,
    authToken: ByteArray? = null,
    network: Network? = null,
) {
    private val authPreamble = byteArrayOf(0x53, 0x53, 0x57, 0x43) // "SSWC"

    @Volatile
    private var controlAuthToken: ByteArray? = authToken?.clone()

    @Volatile
    private var boundNetwork: Network? = network

    var onLatencyMeasured: ((Double) -> Unit)? = null

    /** Server→client brightness command: 0..255, apply to the REAL panel. */
    var onBrightnessCommand: ((Int) -> Unit)? = null

    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    private var connectionGeneration = 0L

    @Volatile
    private var tcpActive = false

    @Volatile
    private var running = false

    @Volatile
    private var connecting = false

    @Volatile
    private var sessionGeneration = 0L

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
        synchronized(connectLock) {
            if (running) return
            running = true
        }
        Thread({ connectionLoop() }, "ControlConnection")
            .apply {
                isDaemon = true
                priority = Thread.MAX_PRIORITY
            }.start()
    }

    private fun connectionLoop() {
        var retryDelayMs = INITIAL_RETRY_MS
        while (running) {
            if (!tcpActive) {
                if (tryTcp()) {
                    retryDelayMs = INITIAL_RETRY_MS
                    continue
                }
                sleepInterruptibly(retryDelayMs)
                retryDelayMs = (retryDelayMs * 2).coerceAtMost(MAX_RETRY_MS)
                continue
            }

            // MainActivity already calls sendPing once per second. This slower
            // safety poll is only a backstop for a ping whose caller disappears
            // before the next tick; 4 wakeups/sec bought no useful latency.
            val probe = outstandingPing
            if (probe != null && System.nanoTime() - probe.sentAtNs > PONG_TIMEOUT_NS) {
                val active = activeTransport()
                if (active != null && active.generation == probe.connectionGeneration) {
                    DiagLog.log("CC", "Control pong timeout — reconnecting")
                    markTcpInactive(active.socket)
                } else if (active == null || active.generation != probe.connectionGeneration) {
                    outstandingPing = null
                }
            }
            sleepInterruptibly(HEALTH_POLL_MS)
        }
    }

    private fun sleepInterruptibly(delayMs: Long) {
        try {
            Thread.sleep(delayMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    /** One bounded connection attempt. Never holds connectLock across I/O. */
    private fun tryTcp(): Boolean {
        synchronized(connectLock) {
            if (!running || tcpActive || socket != null || connecting) return tcpActive
            connecting = true
        }

        // Snapshot the Android Network used for this attempt. If a roam occurs
        // while connect/auth is in flight, the completed socket is discarded
        // rather than installing a route that was obsolete before promotion.
        val targetNetwork = boundNetwork
        val s = Socket()
        return try {
            targetNetwork?.let { network ->
                network.bindSocket(s)
                DiagLog.log("CC", "Control socket bound to Android network $network")
            }
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            val controlOutput = DataOutputStream(s.getOutputStream())
            writeAuthenticationPreamble(controlOutput)
            s.soTimeout = 0

            val installedGeneration =
                synchronized(connectLock) {
                    connecting = false
                    if (!running || socket != null || boundNetwork != targetNetwork) {
                        if (boundNetwork != targetNetwork) {
                            DiagLog.log("CC", "Control connect finished on retired Android network — retrying")
                        }
                        try {
                            s.close()
                        } catch (_: Exception) {
                        }
                        return false
                    }
                    connectionGeneration += 1
                    socket = s
                    output = controlOutput
                    tcpActive = true
                    outstandingPing = null
                    connectionGeneration
                }

            DiagLog.log("CC", "Control channel ACTIVE mode=tcp generation=$installedGeneration")
            declareBrightnessSupport()
            Thread({ tcpReadLoop(s, installedGeneration) }, "ControlTcpThread")
                .apply {
                    isDaemon = true
                    priority = Thread.MAX_PRIORITY
                }.start()
            true
        } catch (e: Exception) {
            synchronized(connectLock) {
                connecting = false
                if (socket === s) {
                    connectionGeneration += 1
                    socket = null
                    output = null
                    tcpActive = false
                    outstandingPing = null
                }
            }
            DiagLog.log(
                "CC",
                "Control channel TCP connect failed: ${e.javaClass.simpleName}: ${e.message}",
            )
            try {
                s.close()
            } catch (_: Exception) {
            }
            false
        }
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
        val pongBuffer = ByteArray(16)
        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 4096))
            while (running && isTransportCurrent(s, generation)) {
                val type = input.readByte().toInt()
                val arrival = System.nanoTime()
                when (type) {
                    5 -> {
                        input.readFully(pongBuffer)
                        val clientTs = readLongLE(pongBuffer, 0)
                        val probe = outstandingPing
                        if (probe?.connectionGeneration == generation && probe.sentAtNs == clientTs) {
                            outstandingPing = null
                        }
                        val rtt = (arrival - clientTs) / 1_000_000.0
                        val processedAt = System.nanoTime()
                        val appDelay = (processedAt - arrival) / 1_000_000.0
                        DiagLog.log(
                            "CC",
                            String.format(
                                "PONG rtt=%.2fms appDelay=%.3fms transit=%.2fms mode=tcp",
                                rtt,
                                appDelay,
                                rtt - appDelay,
                            ),
                        )
                        onLatencyMeasured?.invoke(rtt)
                    }

                    11 -> {
                        val value = input.readByte().toInt() and 0xFF
                        DiagLog.log("CC", "BRIGHT command value=$value")
                        onBrightnessCommand?.invoke(value)
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

    /**
     * Rebind immediately when Android gives the video path a different Network
     * handle. Keeping the previous control TCP socket until its ping timeout
     * would lose low-latency input after an otherwise successful Wi-Fi roam.
     */
    fun setNetwork(network: Network?) {
        val previous = boundNetwork
        if (previous == network) return
        boundNetwork = network

        val activeSocket = synchronized(connectLock) { socket }
        if (activeSocket != null) {
            DiagLog.log("CC", "Android network changed $previous -> $network — rebinding control")
            markTcpInactive(activeSocket)
        }
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

    fun sendPing(): Boolean {
        val transport = activeTransport() ?: return false
        val now = System.nanoTime()
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return false

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
                outstandingPing = OutstandingPing(transport.generation, now)
                transport.output.write(pingPacketScratch)
                true
            } catch (e: Exception) {
                outstandingPing = null
                DiagLog.log("CC", "Control ping write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
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
            }
        }
    }

    fun disconnect() {
        synchronized(connectLock) {
            running = false
            connecting = false
            connectionGeneration += 1
            tcpActive = false
            output = null
            outstandingPing = null
            val activeSocket = socket
            socket = null
            try {
                activeSocket?.close()
            } catch (_: Exception) {
            }
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

        const val CONNECT_TIMEOUT_MS = 2_000
        const val INITIAL_RETRY_MS = 250L
        const val MAX_RETRY_MS = 5_000L
        const val HEALTH_POLL_MS = 1_000L
        const val PONG_TIMEOUT_NS = 4_000_000_000L
    }
}
