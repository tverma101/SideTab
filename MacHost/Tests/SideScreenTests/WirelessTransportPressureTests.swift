import XCTest
@testable import SideScreen

final class WirelessTransportPressureTests: XCTestCase {
    func testWirelessBackpressuresAtTwoOutstandingSends() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)

        WirelessTransportPressure.beginSend(generation: generation)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)

        WirelessTransportPressure.beginSend(generation: generation)
        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding)

        WirelessTransportPressure.completeSend(generation: generation)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
    }

    func testWirelessBackpressuresWhenEncodedBytesReachBudget() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)

        WirelessTransportPressure.beginSend(
            generation: generation,
            bytes: WirelessFreshnessPolicy.maxSenderInFlightBytes
        )

        let snapshot = WirelessTransportPressure.snapshotForTest()
        XCTAssertEqual(WirelessFreshnessPolicy.maxSenderInFlightBytes, snapshot.bytesInFlight)
        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding)

        WirelessTransportPressure.completeSend(
            generation: generation,
            bytes: WirelessFreshnessPolicy.maxSenderInFlightBytes
        )
        XCTAssertEqual(0, WirelessTransportPressure.snapshotForTest().bytesInFlight)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
    }

    func testDeepTcpSendQueueCreatesOnlyBoundedPause() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_000_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            queuedBytes: UInt32(16 * 1024 + WirelessFreshnessPolicy.maxQueuedBacklogBytes + 1),
            frameBytes: 16 * 1024,
            nowNs: now
        )

        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 20_000_000))
    }

    /// Regression: the gate used to read this value as free headroom, so a
    /// healthy queue holding one ordinary frame paused encoding and a full
    /// buffer released it. An idle socket reports 0.
    func testShallowOrEmptyTcpSendQueueNeverPausesHealthyRoute() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_500_000_000

        for queued in [0, 16 * 1024, 16 * 1024 + WirelessFreshnessPolicy.maxQueuedBacklogBytes] {
            WirelessTransportPressure.observeSendBuffer(
                generation: generation,
                queuedBytes: UInt32(queued),
                frameBytes: 16 * 1024,
                nowNs: now
            )
            XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 1), "queued=\(queued)")
        }
    }

    /// Regression: an absolute 64 KiB limit paused on every healthy large
    /// frame (scrolling at 0.75x encode scale: ~110 KiB frames, 22% skipped).
    func testLargeFrameFillingTheQueueByItselfIsNotBacklog() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_750_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            queuedBytes: 128 * 1024,
            frameBytes: 110 * 1024,
            nowNs: now
        )
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
    }

    func testDrainedTcpSendQueueReleasesOlderBufferPauseImmediately() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 2_000_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            queuedBytes: 128 * 1024,
            frameBytes: 48 * 1024,
            nowNs: now
        )
        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            queuedBytes: 4 * 1024,
            frameBytes: 48 * 1024,
            nowNs: now + 2
        )
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 3))
    }

    func testUsbIgnoresBothSubmissionAndSendBufferPressure() {
        let generation = WirelessTransportPressure.reset(wireless: false)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            queuedBytes: 128 * 1024,
            frameBytes: 1_000_000,
            nowNs: 100
        )
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: 101))
    }

    func testLateCompletionAndBufferSampleCannotAlterReplacementGeneration() {
        let oldGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: oldGeneration)
        WirelessTransportPressure.beginSend(generation: oldGeneration)
        WirelessTransportPressure.beginSend(generation: oldGeneration)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        WirelessTransportPressure.beginSend(generation: newGeneration)
        WirelessTransportPressure.completeSend(generation: oldGeneration)
        WirelessTransportPressure.observeSendBuffer(
            generation: oldGeneration,
            queuedBytes: 128 * 1024,
            frameBytes: 500_000,
            nowNs: 100
        )

        let snapshot = WirelessTransportPressure.snapshotForTest()
        XCTAssertEqual(newGeneration, snapshot.generation)
        XCTAssertEqual(1, snapshot.sendsInFlight)
        XCTAssertEqual(0, snapshot.bytesInFlight)
        XCTAssertNil(snapshot.queuedSendBytes)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: 101))
    }

    func testRetireClearsInFlightBytesAndInvalidatesGeneration() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation, bytes: 128 * 1024)

        WirelessTransportPressure.retire(generation: generation)

        let snapshot = WirelessTransportPressure.snapshotForTest()
        XCTAssertNotEqual(generation, snapshot.generation)
        XCTAssertFalse(snapshot.wireless)
        XCTAssertEqual(0, snapshot.sendsInFlight)
        XCTAssertEqual(0, snapshot.bytesInFlight)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
    }
}
