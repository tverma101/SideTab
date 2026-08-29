package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class SessionControllerTest {
    @Test
    fun streamingRequiresARealRenderedFrame() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.USB)

        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)

        assertTrue(controller.state is SessionController.State.WaitingForFirstFrame)
        assertFalse(controller.isStreaming(generation))

        controller.frameDecoded(generation)
        assertTrue(controller.state is SessionController.State.WaitingForFirstFrame)
        controller.surfaceRendered(generation)

        assertTrue(controller.state is SessionController.State.Streaming)
        assertTrue(controller.shouldForwardTouch())
        assertTrue(controller.ownsBrightness(generation))
    }

    @Test
    fun staleGenerationCannotReenterOrOwnBrightness() {
        val controller = SessionController()
        val oldGeneration = controller.begin(ConnectionMode.USB)
        controller.disconnect("test")
        val newGeneration = controller.begin(ConnectionMode.WIRELESS)

        assertFalse(controller.isCurrent(oldGeneration))
        assertFalse(controller.protocolNegotiated(oldGeneration))
        assertEquals(newGeneration, controller.stateGeneration())
    }

    @Test
    fun controlFailureDegradesStreamingWithoutDisconnectingIt() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.USB)
        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)
        controller.surfaceRendered(generation)
        controller.controlHealthy(generation, false)

        val state = controller.state as SessionController.State.Streaming
        assertEquals(SessionController.ControlHealth.DEGRADED, state.details.control)
        assertTrue(controller.isStreaming(generation))
    }

    @Test
    fun disconnectPublishesOrderedTerminalStates() {
        val controller = SessionController()
        controller.begin(ConnectionMode.USB)
        val observed = mutableListOf<SessionController.State>()
        controller.onStateChanged = { state -> observed += state }

        controller.disconnect("test disconnect")

        assertEquals(2, observed.size)
        assertTrue(observed[0] is SessionController.State.Disconnecting)
        assertTrue(observed[1] is SessionController.State.Disconnected)
    }

    @Test
    fun concurrentBeginsReturnDistinctGenerationsAndStateMatchesAuthoritativeGeneration() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(250) {
                val controller = SessionController()
                val ready = CountDownLatch(2)
                val start = CountDownLatch(1)
                val first = executor.submit<Long> {
                    ready.countDown()
                    start.await()
                    controller.begin(ConnectionMode.USB)
                }
                val second = executor.submit<Long> {
                    ready.countDown()
                    start.await()
                    controller.begin(ConnectionMode.WIRELESS)
                }

                assertTrue(ready.await(2, TimeUnit.SECONDS))
                start.countDown()
                val firstGeneration = first.get(2, TimeUnit.SECONDS)
                val secondGeneration = second.get(2, TimeUnit.SECONDS)

                assertNotEquals(firstGeneration, secondGeneration)
                assertEquals(controller.currentGeneration, controller.stateGeneration())
                assertTrue(
                    controller.currentGeneration == firstGeneration ||
                        controller.currentGeneration == secondGeneration,
                )
            }
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun concurrentReadinessCallbacksCannotLeaveStateBehindActiveDetails() {
        val executor = Executors.newFixedThreadPool(4)
        try {
            repeat(250) {
                val controller = SessionController()
                val generation = controller.begin(ConnectionMode.WIRELESS)
                val ready = CountDownLatch(4)
                val start = CountDownLatch(1)
                val tasks = listOf<() -> Boolean>(
                    { controller.protocolNegotiated(generation) },
                    { controller.displayConfigured(generation, legacyProtocolAccepted = true) },
                    { controller.decoderStarted(generation) },
                    { controller.surfaceRendered(generation) },
                ).map { transition ->
                    executor.submit<Boolean> {
                        ready.countDown()
                        start.await()
                        transition()
                    }
                }

                assertTrue(ready.await(2, TimeUnit.SECONDS))
                start.countDown()
                tasks.forEach { assertTrue(it.get(2, TimeUnit.SECONDS)) }

                val state = controller.state as SessionController.State.Streaming
                assertEquals(generation, state.details.generation)
                assertTrue(state.details.protocolReady)
                assertTrue(state.details.displayConfigured)
                assertTrue(state.details.decoderReady)
                assertTrue(state.details.firstFrameRendered)
            }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun SessionController.stateGeneration(): Long? = when (val state = state) {
        is SessionController.State.Connecting -> state.generation
        is SessionController.State.Negotiating -> state.details.generation
        is SessionController.State.WaitingForFirstFrame -> state.details.generation
        is SessionController.State.Streaming -> state.details.generation
        else -> null
    }
}
