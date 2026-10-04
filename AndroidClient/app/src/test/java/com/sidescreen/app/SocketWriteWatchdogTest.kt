package com.sidescreen.app

import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A Java socket write is not interruptible. When the peer stops reading, the
 * writing thread parks inside `write` until something closes the socket, and
 * because every writer here is serialized behind that thread, one wedged write
 * stalls touch, stylus, keyframe and liveness traffic too. These tests pin the
 * only recovery that works: a deadline on another thread that closes the exact
 * captured socket.
 */
class SocketWriteWatchdogTest {
    @Test
    fun aWriteBlockedByANonDrainingPeerIsReleasedByClosingTheCapturedSocket() {
        val listener = ServerSocket(0)
        val accepted = AtomicReference<Socket>()
        val acceptDone = CountDownLatch(1)
        // The peer accepts and then never reads, exactly like a host whose receive
        // side has stopped while the connection stays ESTABLISHED.
        val acceptor =
            Thread {
                try {
                    val socket = listener.accept()
                    runCatching { socket.receiveBufferSize = 1024 }
                    accepted.set(socket)
                    acceptDone.countDown()
                    // Hold the connection open without draining a single byte.
                    Thread.sleep(TimeUnit.SECONDS.toMillis(30))
                    socket.close()
                } catch (_: Exception) {
                    acceptDone.countDown()
                }
            }
        acceptor.isDaemon = true
        acceptor.start()

        val client = Socket()
        val expiredSocket = AtomicReference<Socket?>()
        val watchdog =
            SocketWriteWatchdog(
                budgetMs = 300,
                pollIntervalMs = 25,
            ) { socket, _ ->
                expiredSocket.set(socket)
                runCatching { socket.close() }
                false
            }
        val writerReturned = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        val writer =
            Thread {
                try {
                    runCatching { client.sendBufferSize = 1024 }
                    client.connect(java.net.InetSocketAddress("127.0.0.1", listener.localPort), 2_000)
                    assertTrue(acceptDone.await(2, TimeUnit.SECONDS))
                    val payload = ByteArray(16 * 1024)
                    var written = 0L
                    val limit = 512L * 1024 * 1024
                    while (written < limit) {
                        val token = watchdog.arm(client)
                        try {
                            client.getOutputStream().write(payload)
                        } finally {
                            watchdog.disarm(token)
                        }
                        written += payload.size
                    }
                    // Reaching this point means the send buffer never filled,
                    // which makes the test inconclusive rather than passing.
                    failure.set(AssertionError("peer unexpectedly drained every write"))
                } catch (e: Throwable) {
                    failure.set(e)
                } finally {
                    writerReturned.countDown()
                    runCatching { client.close() }
                }
            }
        writer.isDaemon = true

        try {
            writer.start()
            assertTrue(
                "blocked writer was never released by the watchdog",
                writerReturned.await(20, TimeUnit.SECONDS),
            )
            writer.join(1_000)
            assertFalse("writer thread outlived the test", writer.isAlive)
            assertSame("the deadline must close the actual blocked socket", client, expiredSocket.get())
            val thrown = failure.get()
            assertTrue(
                "expected an IOException from the closed socket, got $thrown",
                thrown is IOException,
            )
        } finally {
            watchdog.shutdown()
            runCatching { client.close() }
            writer.join(TimeUnit.SECONDS.toMillis(1))
            runCatching { accepted.get()?.close() }
            runCatching { listener.close() }
            acceptor.interrupt()
        }
    }

    @Test
    fun aHealthyPeerNeverTripsTheDeadline() {
        val listener = ServerSocket(0)
        val drained = AtomicBoolean(false)
        val drainFinished = CountDownLatch(1)
        val acceptor =
            Thread {
                try {
                    listener.accept().use { socket ->
                        val buffer = ByteArray(4096)
                        while (true) {
                            val read = socket.getInputStream().read(buffer)
                            if (read < 0) break
                        }
                    }
                } catch (_: IOException) {
                    // Listener closed by the test.
                } finally {
                    drained.set(true)
                    drainFinished.countDown()
                }
            }
        acceptor.isDaemon = true
        acceptor.start()

        val client = Socket()
        val fired = AtomicBoolean(false)
        val watchdog =
            SocketWriteWatchdog(
                budgetMs = 150,
                pollIntervalMs = 25,
            ) { socket, _ ->
                fired.set(true)
                runCatching { socket.close() }
                false
            }

        try {
            client.connect(java.net.InetSocketAddress("127.0.0.1", listener.localPort), 2_000)
            repeat(200) { index ->
                val token = watchdog.arm(client)
                try {
                    client.getOutputStream().write(ByteArray(256))
                    client.getOutputStream().flush()
                } finally {
                    watchdog.disarm(token)
                }
            }
            // Several budgets' worth of wall clock with every write already
            // disarmed: a deadline that outlived its write would fire here.
            Thread.sleep(600)
            assertFalse("watchdog fired against a healthy draining peer", fired.get())
            assertFalse(client.isClosed)
        } finally {
            watchdog.shutdown()
            runCatching { client.close() }
            runCatching { listener.close() }
            assertTrue(drainFinished.await(2, TimeUnit.SECONDS))
            assertTrue(drained.get())
        }
    }

    @Test
    fun aStaleDeadlineFromReplacedWorkNeverClosesTheNewerSocket() {
        val stale = Socket()
        val current = Socket()
        val recovered = AtomicReference<Socket?>()
        val watchdog =
            SocketWriteWatchdog(
                budgetMs = 200,
                pollIntervalMs = 20,
            ) { socket, _ ->
                recovered.set(socket)
                false
            }

        try {
            watchdog.arm(stale)
            // Newer work starts before the stale deadline expires.
            watchdog.arm(current)
            Thread.sleep(600)

            assertEquals(
                "the replaced socket was recovered instead of the armed one",
                current,
                recovered.get(),
            )
        } finally {
            watchdog.shutdown()
            runCatching { stale.close() }
            runCatching { current.close() }
        }
    }

    @Test
    fun disarmingBeforeTheDeadlineSuppressesRecovery() {
        val socket = Socket()
        val fired = AtomicBoolean(false)
        val watchdog =
            SocketWriteWatchdog(
                budgetMs = 150,
                pollIntervalMs = 20,
            ) { _, _ ->
                fired.set(true)
                false
            }

        try {
            val firstToken = watchdog.arm(socket)
            watchdog.disarm(firstToken)
            Thread.sleep(400)
            assertFalse("disarmed write must not be recovered", fired.get())
            assertFalse(socket.isClosed)

            // A disarm carrying a retired write's token must not clear the newer
            // write's deadline, so that deadline is still recovered on time.
            val secondToken = watchdog.arm(socket)
            watchdog.disarm(firstToken)
            Thread.sleep(400)
            assertTrue("a stale disarm cleared the live deadline", fired.get())
            watchdog.disarm(secondToken)
        } finally {
            watchdog.shutdown()
            runCatching { socket.close() }
        }
    }

    @Test
    fun rearmingTheSameSocketReplacesTheExpiredDeadlineWithoutAStaleClose() {
        val socket = Socket()
        val fired = AtomicBoolean(false)
        val watchdog =
            SocketWriteWatchdog(
                budgetMs = 1_000,
                pollIntervalMs = 20,
            ) { _, _ ->
                fired.set(true)
                false
            }

        try {
            // A slow but healthy write is almost past the original budget when a
            // newer write re-arms the very same socket. If the expired deadline
            // from the earlier write survived, the next poll would close it.
            watchdog.arm(socket)
            Thread.sleep(300)
            val currentToken = watchdog.arm(socket)
            Thread.sleep(800)
            watchdog.disarm(currentToken)
            Thread.sleep(400)

            assertFalse("an expired deadline closed a re-armed, live socket", fired.get())
            assertFalse(socket.isClosed)
        } finally {
            watchdog.shutdown()
            runCatching { socket.close() }
        }
    }
}
