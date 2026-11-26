package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
    fun readinessFailureInvalidatesTransportBeforeTeardown() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.USB)
        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)

        assertTrue(
            controller.fail(
                generation,
                "Mac accepted the connection, but no video frame was rendered.",
                SessionLifecyclePolicy.EndReason.VIDEO_TRANSPORT_LOST,
            ),
        )
        assertTrue(controller.state is SessionController.State.Failed)
        assertFalse(controller.hasTransport())
        assertFalse(controller.isCurrent(generation))
        assertFalse(controller.surfaceRendered(generation))
    }

    @Test
    fun hostSuspendInvalidatesPixelsAndStaleCallbacksCannotRestoreStreaming() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.WIRELESS)
        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)
        controller.surfaceRendered(generation)

        assertTrue(
            controller.suspend(
                generation,
                SessionLifecyclePolicy.EndReason.HOST_SUSPENDED,
                "Mac locked",
            ),
        )
        assertTrue(controller.state is SessionController.State.SuspendedWaitingForHost)
        assertFalse(controller.hasTransport())
        assertFalse(controller.protocolNegotiated(generation))

        val next = controller.beginAutomaticReconnect(ConnectionMode.WIRELESS, attempt = 1)
        assertTrue(next != null)
        assertTrue(controller.state is SessionController.State.Reconnecting)
    }

    @Test
    fun explicitDisconnectSuppressesAutomaticReconnectUntilManualBegin() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.WIRELESS)
        controller.disconnect("user requested disconnect")

        assertEquals(SessionLifecyclePolicy.EndReason.USER_DISCONNECTED, controller.lastTerminationReason)
        assertFalse(
            SessionLifecyclePolicy.shouldAutoReconnect(
                SessionLifecyclePolicy.ReconnectContext(
                    pairedHostAvailable = true,
                    appForeground = true,
                    reconnectAlreadyRunning = false,
                    healthySessionExists = false,
                    endReason = controller.lastTerminationReason!!,
                ),
            ),
        )

        val manualGeneration = controller.begin(ConnectionMode.WIRELESS)
        assertTrue(manualGeneration > generation)
        assertEquals(null, controller.lastTerminationReason)
    }

    private fun SessionController.stateGeneration(): Long? = when (val state = state) {
        is SessionController.State.Connecting -> state.generation
        is SessionController.State.Negotiating -> state.details.generation
        is SessionController.State.WaitingForFirstFrame -> state.details.generation
        is SessionController.State.Streaming -> state.details.generation
        is SessionController.State.Reconnecting -> state.generation
        else -> null
    }
}
