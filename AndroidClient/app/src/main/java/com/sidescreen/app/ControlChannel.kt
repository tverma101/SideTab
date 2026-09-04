package com.sidescreen.app

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
 * pings/pongs, so a pong is never queued behind video frames (the in-band path's ~40-1000ms
 * spikes under load). The tunnel's TCP carriage stall was fixed by replacing
 * toybox nc (no TCP_NODELAY) with a NODELAY relay on the tablet side, so a
 * dedicated TCP control connection now rides at true tunnel latency.
 *
 * Wire format (little-endian):
 *   client -> server: PING     = [type 4][clientTs 8]
 *   client -> server: KEYFRAME = [type 7][flags 1]
 *   client -> server: SUPPORT_BRIGHTNESS = [type 3]   (payload-free capability)
 *   client -> server: STYLUS = [type 14][fixed 27-byte stylus payload]
 *   server -> client: PONG     = [type 5][clientTs 8 (echo)][serverSendTs 8]
 *   server -> client: BRIGHT   = [type 11][value 1]   (0..255, real backlight)
 */
class ControlChannel(
    private val host: String,
    private val port: Int,
    authToken: ByteArray? = null,
) {
    private val authPreamble = byteArrayOf(0x53, 0x53, 0x57, 0x43) // "SSWC"
    @Volatile
    private var controlAuthToken: ByteArray? = authToken

    var onLatencyMeasured: ((Double) -> Unit)? = null

    /** Server→client brightness command: 0..255, apply to the REAL panel. */
    var onBrightnessCommand: ((Int) -> Unit)? = null

    // TCP path
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    @Volatile
    private var tcpActive = false

    @Volatile
    private var running = false

    private val sendLock = Any()
    private val connectLock = Any()

    val isConnected: Boolean
        get() = tcpActive

    /** Best-effort, one attempt per stream session; failures fall back to in-band messages. */
    fun connect() {
        synchronized(connectLock) {
            if (running) return
            running = true
        }
        Thread({ tryTcp() }, "ControlConnection")
            .apply {
                isDaemon = true
                priority = Thread.MAX_PRIORITY
            }.start()
    }

    private fun tryTcp() {
        synchronized(connectLock) {
            if (!running || socket != null) return
            val s = Socket()
            try {
                // Bounded connect: never let the control path hang the caller.
                s.connect(InetSocketAddress(host, port), 2000)
                s.tcpNoDelay = true
                socket = s
                val controlOutput = DataOutputStream(s.getOutputStream())
                output = controlOutput
                // Active from connect, NOT from the first pong: StreamClient
                // only pings via control when isConnected, so waiting for a
                // pong before declaring active deadlocks the first ping.
                writeAuthenticationPreamble(controlOutput)
                // An idle control channel is valid while the tablet is
                // backgrounded or between pings. A short read timeout would
                // permanently disable this channel after a few quiet seconds
                // and make the next foreground ping fall back to stale
                // in-band traffic. Socket close/disconnect and the next ping
                // write still detect a dead peer.
                s.soTimeout = 0
                tcpActive = true
                DiagLog.log("CC", "Control channel ACTIVE mode=tcp")
                declareBrightnessSupport()
                Thread({ tcpReadLoop(s) }, "ControlTcpThread")
                    .apply { isDaemon = true }
                    .start()
            } catch (e: Exception) {
                DiagLog.log("CC", "Control channel TCP connect failed: ${e.javaClass.simpleName}: ${e.message}")
                socket = null
                output = null
                tcpActive = false
                running = false
                try {
                    s.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun tcpReadLoop(s: Socket) {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
        } catch (_: Exception) {
        }
        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 4096))
            while (running && socket === s) {
                val type = input.readByte().toInt()
                val arrival = System.nanoTime()
                when (type) {
                    5 -> { // Pong: [clientTs 8][serverSendTs 8]
                        val buf = ByteArray(16)
                        input.readFully(buf)
                        val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
                        val clientTs = bb.long
                        bb.long // server send timestamp; RTT uses the echoed client timestamp.
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
                        if (!tcpActive) {
                            tcpActive = true
                            DiagLog.log("CC", "Control channel ACTIVE mode=tcp")
                        }
                        onLatencyMeasured?.invoke(rtt)
                    }

                    11 -> { // Bright: [value 1] 0..255 — REAL panel backlight
                        val value = input.readByte().toInt() and 0xFF
                        DiagLog.log("CC", "BRIGHT command value=$value")
                        onBrightnessCommand?.invoke(value)
                    }

                    else -> {
                        DiagLog.log("CC", "Unknown control type $type — disconnecting")
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running) {
                DiagLog.log("CC", "Control read error: ${e.javaClass.simpleName}: ${e.message}")
            }
        } finally {
            markTcpInactive(s)
        }
    }

    /** Set the token used for the next control-channel connection. */
    fun setAuthToken(token: ByteArray?) {
        controlAuthToken = token?.clone()
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

    /** Tell the server we understand BRIGHT (type 11). Old servers log-only. */
    private fun declareBrightnessSupport() {
        val out = output ?: return
        synchronized(sendLock) {
            try {
                out.write(byteArrayOf(3))
                out.flush()
                DiagLog.log("CC", "Declared brightness support")
            } catch (e: Exception) {
                DiagLog.log("CC", "Brightness declaration failed: ${e.message}")
            }
        }
    }

    /** Returns false when the caller should use its in-band fallback. */
    fun sendPing(): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        val ts = System.nanoTime()
        synchronized(sendLock) {
            return try {
                val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                buffer.put(4.toByte())
                buffer.putLong(ts)
                out.write(buffer.array())
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control ping write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    /** Returns false when the caller should use its in-band fallback. */
    fun requestKeyframe(force: Boolean): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        synchronized(sendLock) {
            return try {
                out.write(byteArrayOf(7.toByte(), if (force) 1 else 0))
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control keyframe write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(activeSocket)
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
    ): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
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
            return try {
                out.write(buffer.array())
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control touch write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    /** Send one negotiated S Pen event without passing through touch gestures. */
    fun sendStylus(event: StylusInputEvent): Boolean {
        val activeSocket = socket ?: return false
        val out = output ?: return false
        val bytes = StylusProtocol.encode(event)
        synchronized(sendLock) {
            return try {
                out.write(bytes)
                out.flush()
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control stylus write failed: ${e.javaClass.simpleName}: ${e.message}")
                markTcpInactive(activeSocket)
                false
            }
        }
    }

    private fun markTcpInactive(expectedSocket: Socket) {
        synchronized(connectLock) {
            if (socket !== expectedSocket) return
            tcpActive = false
            output = null
            socket = null
            try {
                expectedSocket.close()
            } catch (_: Exception) {
            }
            if (running) {
                running = false
                DiagLog.log("CC", "Control channel inactive — using in-band fallback until next Connect")
            }
        }
    }

    fun disconnect() {
        synchronized(connectLock) {
            running = false
            tcpActive = false
            output = null
            val activeSocket = socket
            socket = null
            try {
                activeSocket?.close()
            } catch (_: Exception) {
            }
        }
    }

}
