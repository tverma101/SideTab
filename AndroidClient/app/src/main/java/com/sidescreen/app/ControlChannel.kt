package com.sidescreen.app

import android.net.Network
import android.os.Process
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

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

    /** Server→client brightness command: 0..255, apply to the real panel. */
    var onBrightnessCommand: ((Int) -> Unit)? = null

    private var socket: Socket? = null
    private var output: DataOutputStream? = null

    /** Monotonic identity for each installed control TCP transport. */
    private var connectionGeneration = 0L

    @Volatile
    private var tcpActive = false

    /** Desired lifetime of the channel, not the state of the current socket. */
    @Volatile
    private var running = false

    @Volatile
    private var connecting = false

    /**
     * Video-session generation supplied by StreamClient. Input/control work
     * queued for an older recovered video session is intentionally consumed
     * (dropped) rather than being replayed into the new session.
     */
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

    val isConnected: Boolean
        get() = tcpActive

    /**
     * Start (or keep) the self-healing control channel. Idempotent.
     * Connection failures never fail the video session; they retry with capped
     * backoff while callers use the in-band fallback.
     */
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

            val probe = outstandingPing
            if (probe != null && System.nanoTime() - probe.sentAtNs > PONG_TIMEOUT_NS) {
                val active = activeTransport()
                if (active != null && active.generation == probe.connectionGeneration) {
                    DiagLog.log("CC", "Control pong timeout — reconnecting")
                    markTcpInactive(active.socket)
                } else if (active == null || active.generation != probe.connectionGeneration) {
                    // A stale probe from a retired socket must never kill the
                    // replacement control connection.
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

        val s = Socket()
        return try {
            boundNetwork?.let { network ->
                network.bindSocket(s)
                DiagLog.log("CC", "Control socket bound to Android network $network")
            }
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            val controlOutput = DataOutputStream(s.getOutputStream())
            writeAuthenticationPreamble(controlOutput)
            // Idle is legitimate. Half-open detection is ping-driven above.
            s.soTimeout = 0

            val installedGeneration =
                synchronized(connectLock) {
                    connecting = false
                    if (!running || socket != null) {
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
        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 4096))
            while (running && isTransportCurrent(s, generation)) {
                val type = input.readByte().toInt()
                val arrival = System.nanoTime()
                when (type) {
                    5 -> { // Pong: [clientTs 8][serverSendTs 8]
                        val buf = ByteArray(16)
                        input.readFully(buf)
                        val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
                        val clientTs = bb.long
                        bb.long // Server timestamp; RTT uses echoed client timestamp.
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

                    11 -> { // Bright: [value 1] 0..255 — real panel backlight
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

    /** Set the token used for subsequent control-channel connections. */
    fun setAuthToken(token: ByteArray?) {
        controlAuthToken = token?.clone()
    }

    /** Bind subsequent control sockets to the same Android Network as video. */
    fun setNetwork(network: Network?) {
        boundNetwork = network
    }

    /**
     * Fence queued input against StreamClient's current recovered video
     * transport. Synchronizing with sendLock makes the generation transition
     * atomic relative to an actual control write.
     */
    fun setSessionGeneration(generation: Long) {
        synchronized(sendLock) {
            sessionGeneration = generation
        }
    }

    private fun writeAuthenticationPreamble(out: DataOutputStream) {
        val token = controlAuthToken ?: return // Loopback USB tunnel is already local.
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

    /** Tell the server we understand BRIGHT (type 11). Old servers log-only. */
    private fun declareBrightnessSupport() {
        val transport = activeTransport() ?: return
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return
            try {
                transport.output.write(byteArrayOf(3))
                transport.output.flush()
                DiagLog.log("CC", "Declared brightness support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Brightness declaration failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
            }
        }
    }

    /** Returns false when the caller should use its in-band fallback. */
    fun sendPing(): Boolean {
        val transport = activeTransport() ?: return false
        val ts = System.nanoTime()
        synchronized(sendLock) {
            if (!isTransportCurrent(transport)) return false
            return try {
                val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                buffer.put(4.toByte())
                buffer.putLong(ts)
                val existing = outstandingPing
                if (existing == null || existing.connectionGeneration != transport.generation) {
                    outstandingPing = OutstandingPing(transport.generation, ts)
                }
                transport.output.write(buffer.array())
                transport.output.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control ping write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    /**
     * Returns false when the caller should use its in-band fallback. When an
     * expectedSessionGeneration is supplied and is stale, true means the
     * obsolete operation was intentionally consumed/dropped.
     */
    fun requestKeyframe(
        force: Boolean,
        expectedSessionGeneration: Long? = null,
    ): Boolean {
        val transport = activeTransport() ?: return false
        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false
            return try {
                transport.output.write(byteArrayOf(7.toByte(), if (force) 1 else 0))
                transport.output.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control keyframe write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    /** Send pointer input on the low-latency path, preserving event order. */
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
        val count = pointerCount.coerceIn(1, 2)
        val buffer = ByteBuffer.allocate(6 + count * 8).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(2.toByte())
        buffer.put(count.toByte())
        buffer.putFloat(x)
        buffer.putFloat(y)
        if (count == 2) {
            buffer.putFloat(x2)
            buffer.putFloat(y2)
        }
        buffer.putInt(action)

        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false
            return try {
                transport.output.write(buffer.array())
                transport.output.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control touch write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(transport.socket)
                false
            }
        }
    }

    /** Send one negotiated S Pen event without passing through touch gestures. */
    fun sendStylus(
        event: StylusInputEvent,
        expectedSessionGeneration: Long? = null,
    ): Boolean {
        val transport = activeTransport() ?: return false
        val bytes = StylusProtocol.encode(event)
        synchronized(sendLock) {
            if (expectedSessionGeneration != null && sessionGeneration != expectedSessionGeneration) return true
            if (!isTransportCurrent(transport)) return false
            return try {
                transport.output.write(bytes)
                transport.output.flush()
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

    private companion object {
        const val CONNECT_TIMEOUT_MS = 2_000
        const val INITIAL_RETRY_MS = 250L
        const val MAX_RETRY_MS = 5_000L
        const val HEALTH_POLL_MS = 250L
        const val PONG_TIMEOUT_NS = 4_000_000_000L
    }
}
