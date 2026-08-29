package com.sidescreen.app

import java.util.ArrayDeque

/**
 * The single Android session truth.
 *
 * Transport readiness and the local USB checklist are deliberately not the
 * same thing. A session becomes Streaming only after the current generation
 * has negotiated a valid display, started a decoder, and reached the render
 * path. Control-channel health is a capability of that stream, not stream
 * liveness.
 *
 * State, generation and active details are committed atomically under [lock].
 * UI callbacks are then drained in that exact transition order by one drainer.
 * This prevents overlapping transport/decoder callbacks from publishing an old
 * state snapshot after a newer generation has already become authoritative.
 */
class SessionController {
    enum class ControlHealth {
        UNKNOWN,
        HEALTHY,
        DEGRADED,
    }

    data class Details(
        val generation: Long,
        val mode: ConnectionMode,
        val protocolReady: Boolean,
        val displayConfigured: Boolean,
        val decoderReady: Boolean,
        val firstFrameDecoded: Boolean,
        val firstFrameRendered: Boolean,
        val control: ControlHealth,
    )

    sealed interface State {
        object Idle : State

        data class Preflight(val advisories: List<String>) : State

        data class Connecting(
            val generation: Long,
            val mode: ConnectionMode,
        ) : State

        data class Negotiating(val details: Details) : State

        data class WaitingForFirstFrame(val details: Details) : State

        data class Streaming(val details: Details) : State

        data class Disconnecting(
            val generation: Long,
            val reason: String,
        ) : State

        data class Disconnected(val reason: String) : State

        data class Failed(
            val reason: String,
            val retryable: Boolean = true,
        ) : State
    }

    @Volatile
    var state: State = State.Idle
        private set

    val currentGeneration: Long
        get() = synchronized(lock) { generationValue }

    /**
     * Compatibility callback for the current Activity UI. #46 will replace
     * direct view mutation with one authoritative UI projection. Callbacks are
     * serialized in transition order even when transport/codec threads race.
     */
    @Volatile
    var onStateChanged: ((State) -> Unit)? = null

    private val lock = Any()
    private var generationValue = 0L
    private var activeDetails: Details? = null

    /**
     * Transitions are committed to [state] while holding [lock], then queued.
     * Exactly one thread drains callbacks. New transitions that arrive while a
     * callback is running append to this queue instead of invoking UI out of
     * order on competing threads.
     */
    private val pendingPublications = ArrayDeque<State>()
    private var drainingPublications = false

    fun begin(mode: ConnectionMode): Long {
        var shouldDrain = false
        val generation = synchronized(lock) {
            generationValue += 1
            val newGeneration = generationValue
            val details = Details(
                generation = newGeneration,
                mode = mode,
                protocolReady = false,
                displayConfigured = false,
                decoderReady = false,
                firstFrameDecoded = false,
                firstFrameRendered = false,
                control = ControlHealth.UNKNOWN,
            )
            activeDetails = details
            shouldDrain = enqueueStateLocked(State.Connecting(newGeneration, mode))
            newGeneration
        }
        if (shouldDrain) drainPublications()
        return generation
    }

    fun transportConnected(generation: Long): Boolean = update(generation) { it }

    /** A codec-selected message proves protocol negotiation; legacy display
     * configuration can also establish the minimum compatible protocol. */
    fun protocolNegotiated(generation: Long): Boolean = update(generation) {
        it.copy(protocolReady = true)
    }

    fun displayConfigured(
        generation: Long,
        legacyProtocolAccepted: Boolean = false,
    ): Boolean = update(generation) {
        it.copy(
            displayConfigured = true,
            protocolReady = it.protocolReady || legacyProtocolAccepted,
        )
    }

    fun decoderStarted(generation: Long): Boolean = update(generation) {
        it.copy(decoderReady = true)
    }

    fun frameDecoded(generation: Long): Boolean = update(generation) {
        it.copy(firstFrameDecoded = true)
    }

    fun surfaceRendered(generation: Long): Boolean = update(generation) {
        it.copy(
            firstFrameDecoded = true,
            firstFrameRendered = true,
        )
    }

    fun controlHealthy(generation: Long, healthy: Boolean): Boolean = update(generation) {
        it.copy(control = if (healthy) ControlHealth.HEALTHY else ControlHealth.DEGRADED)
    }

    fun fail(generation: Long, reason: String): Boolean {
        var shouldDrain = false
        synchronized(lock) {
            if (!isCurrentLocked(generation)) return false
            activeDetails = null
            shouldDrain = enqueueStateLocked(State.Failed(reason = reason))
        }
        if (shouldDrain) drainPublications()
        return true
    }

    /** Idempotent user/lifecycle teardown. Invalidates the old generation
     * before any callbacks from its sockets or decoder can run. */
    fun disconnect(reason: String = "user requested disconnect"): Boolean {
        var shouldDrain = false
        synchronized(lock) {
            val oldGeneration = generationValue
            generationValue += 1
            activeDetails = null
            shouldDrain = enqueueStateLocked(State.Disconnecting(oldGeneration, reason)) || shouldDrain
            shouldDrain = enqueueStateLocked(State.Disconnected(reason)) || shouldDrain
        }
        if (shouldDrain) drainPublications()
        return true
    }

    /** A transport failure is terminal for the current generation, but does
     * not turn advisory preflight into a false "not ready" state. */
    fun transportLost(
        generation: Long,
        reason: String = "video transport closed",
    ): Boolean {
        var shouldDrain = false
        synchronized(lock) {
            if (!isCurrentLocked(generation)) return false
            generationValue += 1
            activeDetails = null
            shouldDrain = enqueueStateLocked(State.Disconnected(reason))
        }
        if (shouldDrain) drainPublications()
        return true
    }

    fun setPreflight(advisories: List<String>) {
        var shouldDrain = false
        synchronized(lock) {
            if (activeDetails != null || state is State.Failed) return
            shouldDrain = enqueueStateLocked(State.Preflight(advisories.distinct()))
        }
        if (shouldDrain) drainPublications()
    }

    fun isCurrent(generation: Long): Boolean = synchronized(lock) {
        isCurrentLocked(generation)
    }

    fun canInitializeDecoder(generation: Long): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        details.generation == generation &&
            details.protocolReady &&
            details.displayConfigured
    }

    fun hasTransport(): Boolean = synchronized(lock) {
        activeDetails?.let { it.protocolReady || it.displayConfigured || it.decoderReady || it.firstFrameDecoded } == true ||
            state is State.Connecting || state is State.Negotiating ||
            state is State.WaitingForFirstFrame || state is State.Streaming
    }

    fun isStreaming(generation: Long? = null): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        state is State.Streaming && (generation == null || details.generation == generation)
    }

    fun shouldForwardTouch(): Boolean = synchronized(lock) {
        state is State.Streaming
    }

    fun ownsBrightness(generation: Long): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        details.generation == generation && state is State.Streaming
    }

    private fun update(
        generation: Long,
        transform: (Details) -> Details,
    ): Boolean {
        var shouldDrain = false
        synchronized(lock) {
            val current = activeDetails ?: return false
            if (current.generation != generation) return false
            val updated = transform(current)
            activeDetails = updated
            shouldDrain = enqueueStateLocked(stateFor(updated))
        }
        if (shouldDrain) drainPublications()
        return true
    }

    private fun isCurrentLocked(generation: Long): Boolean =
        activeDetails?.generation == generation && state !is State.Failed

    private fun stateFor(details: Details): State {
        if (!details.protocolReady || !details.displayConfigured || !details.decoderReady) {
            return State.Negotiating(details)
        }
        if (!details.firstFrameRendered) {
            return State.WaitingForFirstFrame(details)
        }
        return State.Streaming(details)
    }

    /** Must be called with [lock] held. Returns true when the caller became the drainer. */
    private fun enqueueStateLocked(next: State): Boolean {
        if (state == next) return false
        state = next
        pendingPublications.addLast(next)
        if (drainingPublications) return false
        drainingPublications = true
        return true
    }

    /**
     * Delivers every committed transition in the same order it was committed.
     * Reentrant controller calls from the callback simply append more work for
     * this same drainer, so callbacks cannot race each other across threads.
     */
    private fun drainPublications() {
        while (true) {
            val publication = synchronized(lock) {
                if (pendingPublications.isEmpty()) {
                    drainingPublications = false
                    return
                }
                pendingPublications.removeFirst() to onStateChanged
            }

            try {
                publication.second?.invoke(publication.first)
            } catch (error: Throwable) {
                // Never leave the controller permanently marked as draining if
                // a UI observer throws. Preserve the exception for the caller.
                synchronized(lock) {
                    drainingPublications = false
                }
                throw error
            }
        }
    }
}
