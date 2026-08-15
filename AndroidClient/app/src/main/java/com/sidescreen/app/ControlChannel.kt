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
 * TCP-only. The channel's own connection carries nothing but pings/pongs, so
 * a pong is never queued behind video frames (the in-band path's ~40-1000ms
 * spikes under load). The tunnel's TCP carriage stall was fixed by replacing
 * toybox nc (no TCP_NODELAY) with a NODELAY relay on the tablet side, so a
 * dedicated TCP control connection now rides at true tunnel latency.
 *
 * Wire format (little-endian):
 *   client -> server: PING     = [type 4][clientTs 8]
 *   client -> server: KEYFRAME = [type 7][flags 1]
 *   server -> client: PONG     = [type 5][clientTs 8 (echo)][serverSendTs 8]
 */
class ControlChannel(
    private val host: String,
    private val port: Int,
) {
    var onLatencyMeasured: ((Double) -> Unit)? = null

    // TCP path
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    @Volatile
    private var tcpActive = false

    @Volatile
    private var running = false

    @Volatile
    private var lastPongAtNs = 0L

    @Volatile
    private var lastPingSentAtNs = 0L

    private val sendLock = Any()
    private val connectLock = Any()

    val isConnected: Boolean
        get() = tcpActive

    /** Best-effort: never throws — failures fall back to in-band ping/pong. */
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

    /** Keep the optional channel self-healing across relay/VPN/app restarts. */
    private fun connectionLoop() {
        while (running) {
            if (!tcpActive) {
                tryTcp()
            } else {
                val now = System.nanoTime()
                val activeSocket = socket
                if (activeSocket != null &&
                    lastPingSentAtNs > lastPongAtNs &&
                    now - lastPongAtNs > PONG_TIMEOUT_NS
                ) {
                    DiagLog.log("CC", "Control pong timeout — reconnecting")
                    markTcpInactive(activeSocket)
                }
            }
            try {
                Thread.sleep(if (tcpActive) 250 else 500)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
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
                output = DataOutputStream(s.getOutputStream())
                lastPongAtNs = System.nanoTime()
                lastPingSentAtNs = 0L
                // Active from connect, NOT from the first pong: StreamClient
                // only pings via control when isConnected, so waiting for a
                // pong before declaring active deadlocks the first ping.
                tcpActive = true
                DiagLog.log("CC", "Control channel ACTIVE mode=tcp")
                Thread({ tcpReadLoop(s) }, "ControlTcpThread")
                    .apply { isDaemon = true }
                    .start()
            } catch (e: Exception) {
                DiagLog.log("CC", "Control channel TCP connect failed: ${e.message}")
                socket = null
                output = null
                tcpActive = false
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
                        val serverTs = bb.long
                        val rtt = (arrival - clientTs) / 1_000_000.0
                        val processedAt = System.nanoTime()
                        lastPongAtNs = arrival
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

                    else -> {
                        DiagLog.log("CC", "Unknown control type $type — disconnecting")
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running) {
                DiagLog.log("CC", "Control read error: ${e.message}")
            }
        } finally {
            markTcpInactive(s)
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
                lastPingSentAtNs = ts
                true
            } catch (e: Exception) {
                DiagLog.log("CC", "Control ping write failed: ${e.message}")
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
                DiagLog.log("CC", "Control keyframe write failed: ${e.message}")
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
                DiagLog.log("CC", "Control touch write failed: ${e.message}")
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
            lastPongAtNs = 0L
            lastPingSentAtNs = 0L
            try {
                expectedSocket.close()
            } catch (_: Exception) {
            }
            if (running) {
                DiagLog.log("CC", "Control channel inactive — reconnecting")
            }
        }
    }

    fun disconnect() {
        synchronized(connectLock) {
            running = false
            tcpActive = false
            output = null
            lastPongAtNs = 0L
            lastPingSentAtNs = 0L
            val activeSocket = socket
            socket = null
            try {
                activeSocket?.close()
            } catch (_: Exception) {
            }
        }
    }

    private companion object {
        const val PONG_TIMEOUT_NS = 3_000_000_000L
    }
}
