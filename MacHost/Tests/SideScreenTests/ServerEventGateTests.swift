import XCTest
@testable import SideScreen

/// Regression cover for the host's server-callback fence.
///
/// Every case here corresponds to a callback that had already left
/// StreamingServer's queue and was sitting in a `Task { @MainActor }` hop. The
/// gate is the only thing standing between that stale event and either a green
/// "Connected" UI with no client, or a Stop of a healthy replacement server.
///
/// The scenarios drive a REAL `StreamingServer` through `stop()` — the one
/// public transition that ends a session — so the "current generation" the gate
/// reads is server state the test actually moved, not a value it invented.
final class ServerEventGateTests: XCTestCase {
    private func makeServer() -> StreamingServer {
        StreamingServer(port: 0, controlPort: 0)
    }

    private func event(
        _ server: StreamingServer,
        generation: UInt64
    ) -> StreamingServer.SessionEvent {
        StreamingServer.SessionEvent(
            serverID: ObjectIdentifier(server),
            sessionGeneration: generation
        )
    }

    /// The reported failure: a watchdog tick from the retired server lands
    /// after a replacement server is already live. `runtime.isRunning` is true
    /// (the NEW server published it), so the old timeout used to stop it.
    func testTimeoutFromRetiredServerCannotStopTheReplacement() {
        let oldServer = makeServer()
        let newServer = makeServer()
        var gate = ServerEventGate()

        gate.adopt(oldServer)
        XCTAssertTrue(gate.accepts(oldServer.currentSessionEvent(), liveServer: oldServer))
        gate.retire(oldServer)
        gate.adopt(newServer)

        XCTAssertFalse(
            gate.accepts(oldServer.currentSessionEvent(), liveServer: newServer),
            "a timeout queued by the retired server must never stop the new one"
        )
        XCTAssertTrue(gate.accepts(event(newServer, generation: 0), liveServer: newServer))
    }

    /// The hazard the gate's own bookkeeping cannot see. The server installs a
    /// new session while the previous session's timeout is still queued, so the
    /// timeout's generation is the newest the host has applied — yet it
    /// describes a session that no longer exists and must not stop the live
    /// one. Real `stop()` moves the server's locked generation forward.
    func testOldTimeoutCannotStopASessionInstalledAfterItWasQueued() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)

        let queuedTimeout = server.currentSessionEvent()
        server.stop()  // a new session takes over: the generation moves on

        XCTAssertNotEqual(
            queuedTimeout.sessionGeneration,
            server.currentSessionSnapshot().generation,
            "stop() must advance the generation so pre-stop events are stale"
        )
        XCTAssertFalse(
            gate.accepts(queuedTimeout, liveServer: server),
            "a timeout queued before the next session must not stop it"
        )
    }

    /// The other half of the same hazard: `onClientConnected` and
    /// `onClientDisconnected` are two separate MainActor tasks. A rapid
    /// connect-then-disconnect can therefore run in the order the host applied
    /// them, not the order the server emitted them. Applying the stale connect
    /// last left `runtime.clientConnected == true` forever.
    func testQueuedConnectAfterDisconnectCannotRepublishConnected() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)

        // The server ends its session while a connect from it is still queued;
        // the host then applies the disconnect first and the connect second.
        let queuedConnect = server.currentSessionEvent()
        server.stop()
        let disconnect = server.currentSessionEvent()

        XCTAssertTrue(gate.accepts(disconnect, liveServer: server))
        XCTAssertFalse(
            gate.accepts(queuedConnect, liveServer: server),
            "a connect older than the session now live must be rejected"
        )
    }

    /// A repeated terminal event for the same generation is legal: the timeout
    /// path deliberately reports the disconnect and then the escalation, and
    /// both carry the post-disconnect generation. The second must still be
    /// allowed to act.
    func testSameGenerationTimeoutAfterDisconnectIsStillAccepted() {
        let server = makeServer()
        server.stop()
        var gate = ServerEventGate()
        gate.adopt(server)
        let timedOut = server.currentSessionEvent()

        XCTAssertTrue(gate.accepts(timedOut, liveServer: server))
        XCTAssertTrue(gate.accepts(timedOut, liveServer: server))
    }

    /// Metrics are per-session: a sample counted while the previous session was
    /// live must not overwrite the numbers of the session that replaced it.
    func testStatsFromThePreviousSessionAreRejectedAfterItEnds() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)

        let drainedSample = server.currentSessionEvent()
        server.stop()

        XCTAssertFalse(gate.accepts(drainedSample, liveServer: server))
    }

    /// With no server published there is nothing an event can still describe.
    func testEventsAreRejectedWhenNoServerIsPublished() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)

        XCTAssertFalse(gate.accepts(server.currentSessionEvent(), liveServer: nil))
    }

    func testEventsBeforeAdoptionAreRejected() {
        let server = makeServer()
        var gate = ServerEventGate()

        XCTAssertFalse(gate.accepts(server.currentSessionEvent(), liveServer: server))
        XCTAssertFalse(gate.acceptsFromActiveServer(server.currentSessionEvent()))
    }

    func testRetiringAForeignServerDoesNotClearTheActiveOne() {
        let active = makeServer()
        let other = makeServer()
        var gate = ServerEventGate()
        gate.adopt(active)

        gate.retire(other)

        XCTAssertTrue(gate.accepts(active.currentSessionEvent(), liveServer: active))
    }

    /// Pairing is reported before the session is installed, so the handshake
    /// completing moves the generation underneath the hop. The device really
    /// did pair, so that event is judged on identity alone.
    func testPairingSurvivesTheGenerationBumpOfItsOwnHandshake() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)

        let pairing = server.currentSessionEvent()
        server.stop()  // the handshake completing installs the session

        XCTAssertTrue(
            gate.acceptsFromActiveServer(pairing),
            "a device that paired must still be recorded after its session starts"
        )
        XCTAssertFalse(
            gate.acceptsFromActiveServer(event(makeServer(), generation: 0)),
            "pairing from a server that is no longer on air must be rejected"
        )
    }

    func testAcceptedAndRejectedCountsAreTrackedForDiagnostics() {
        let server = makeServer()
        var gate = ServerEventGate()
        gate.adopt(server)
        let stale = server.currentSessionEvent()
        server.stop()

        XCTAssertFalse(gate.accepts(stale, liveServer: server))
        XCTAssertTrue(gate.accepts(server.currentSessionEvent(), liveServer: server))

        XCTAssertEqual(gate.acceptedEventCount, 1)
        XCTAssertEqual(gate.rejectedEventCount, 1)
    }

    /// `StartGeneration.isCurrent` goes false the moment a start finishes, so
    /// it cannot be reused as a live-callback fence. This test documents the
    /// difference that motivated a separate type.
    func testStartGenerationIsNotALiveCallbackFence() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())
        XCTAssertTrue(generation.isCurrent(token))

        generation.finish(token)

        XCTAssertFalse(
            generation.isCurrent(token),
            "a finished start is live but no longer 'current'; using it to fence callbacks would reject every real event"
        )
    }
}
