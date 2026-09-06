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
        XCTAssertEqual(.pause, WirelessTransportPressure.captureAdmission)

        WirelessTransportPressure.completeSend(generation: generation)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission)
    }

    func testSingleLargeSendPausesUntilOutstandingSetDrains() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 500_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 1_024 * 1024,
            frameBytes: 300 * 1024,
            nowNs: now
        )
        WirelessTransportPressure.beginSend(generation: generation)

        XCTAssertEqual(.pause, WirelessTransportPressure.captureAdmission(at: now + 1))
        XCTAssertTrue(WirelessTransportPressure.snapshotForTest().largeSendOutstanding)

        WirelessTransportPressure.completeSend(generation: generation)
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission(at: now + 2))
        XCTAssertFalse(WirelessTransportPressure.snapshotForTest().largeSendOutstanding)
    }

    func testLowTcpHeadroomCreatesOnlyBoundedPause() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_000_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 8 * 1024,
            frameBytes: 64 * 1024,
            nowNs: now
        )

        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
        XCTAssertEqual(.pause, WirelessTransportPressure.captureAdmission(at: now + 1))
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 20_000_000))
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission(at: now + 20_000_000))
    }

    func testFrameThatWouldConsumeTcpReservePausesNextEncode() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_500_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 80 * 1024,
            frameBytes: 64 * 1024,
            nowNs: now
        )

        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 20_000_000))
    }

    func testReserveTracksCurrentFrameSizeNotOnlyFixedFloor() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_650_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 120 * 1024,
            frameBytes: 64 * 1024,
            nowNs: now
        )

        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
    }

    func testHealthyProjectedHeadroomDoesNotPause() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_750_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 256 * 1024,
            frameBytes: 64 * 1024,
            nowNs: now
        )

        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
    }

    func testHealthyTcpHeadroomReleasesOlderBufferPauseImmediately() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 2_000_000_000

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 4 * 1024,
            frameBytes: 48 * 1024,
            nowNs: now
        )
        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 256 * 1024,
            frameBytes: 48 * 1024,
            nowNs: now + 2
        )
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 3))
    }

    func testForcedCaptureAdmissionIsGenerationFenced() {
        let oldGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: oldGeneration)
        let oldMarker = WirelessTransportPressure.noteForcedCapturePending()
        XCTAssertEqual(oldGeneration, oldMarker)
        XCTAssertEqual(.forced, WirelessTransportPressure.captureAdmission)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        let newMarker = WirelessTransportPressure.noteForcedCapturePending()
        XCTAssertEqual(newGeneration, newMarker)
        XCTAssertEqual(.forced, WirelessTransportPressure.captureAdmission)

        WirelessTransportPressure.clearForcedCapturePending(generation: oldGeneration)
        XCTAssertEqual(.forced, WirelessTransportPressure.captureAdmission)

        WirelessTransportPressure.clearForcedCapturePending(generation: newGeneration)
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission)
    }

    func testForcedAdmissionOverridesActivePressure() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        XCTAssertEqual(.pause, WirelessTransportPressure.captureAdmission)

        XCTAssertEqual(generation, WirelessTransportPressure.noteForcedCapturePending())
        XCTAssertEqual(.forced, WirelessTransportPressure.captureAdmission)
    }

    func testTelemetryTracksCompletionHeadroomAndAdmission() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)

        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 512 * 1024,
            frameBytes: 64 * 1024,
            nowNs: 1_000
        )
        WirelessTransportPressure.beginSend(generation: generation, nowNs: 2_000)
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission(at: 2_001))
        WirelessTransportPressure.completeSend(generation: generation, nowNs: 12_000)

        let metrics = WirelessTransportPressure.telemetrySnapshotForTest()
        XCTAssertEqual(1, metrics.completionSamples)
        XCTAssertEqual(10_000, metrics.completionTotalNs)
        XCTAssertEqual(10_000, metrics.completionMaxNs)
        XCTAssertEqual(1, metrics.headroomSamples)
        XCTAssertEqual(UInt64(512 * 1024), metrics.headroomTotalBytes)
        XCTAssertEqual(UInt32(512 * 1024), metrics.headroomMinBytes)
        XCTAssertEqual(0, metrics.capturePauseDecisions)
        XCTAssertEqual(0, metrics.captureForcedDecisions)
    }

    func testTelemetryCountsPauseAndForcedAdmissions() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation, nowNs: 100)
        WirelessTransportPressure.beginSend(generation: generation, nowNs: 200)

        XCTAssertEqual(.pause, WirelessTransportPressure.captureAdmission(at: 201))
        XCTAssertEqual(generation, WirelessTransportPressure.noteForcedCapturePending())
        XCTAssertEqual(.forced, WirelessTransportPressure.captureAdmission(at: 202))

        let metrics = WirelessTransportPressure.telemetrySnapshotForTest()
        XCTAssertEqual(1, metrics.capturePauseDecisions)
        XCTAssertEqual(1, metrics.captureForcedDecisions)
    }

    func testReplacementGenerationResetsAndFencesTelemetry() {
        let oldGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: oldGeneration)
        WirelessTransportPressure.observeSendBuffer(
            generation: oldGeneration,
            availableBytes: 128 * 1024,
            frameBytes: 32 * 1024,
            nowNs: 100
        )
        WirelessTransportPressure.beginSend(generation: oldGeneration, nowNs: 200)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        WirelessTransportPressure.completeSend(generation: oldGeneration, nowNs: 5_000)
        WirelessTransportPressure.observeSendBuffer(
            generation: oldGeneration,
            availableBytes: 1,
            frameBytes: 1,
            nowNs: 5_001
        )

        let metrics = WirelessTransportPressure.telemetrySnapshotForTest()
        XCTAssertEqual(0, metrics.completionSamples)
        XCTAssertEqual(0, metrics.headroomSamples)
        XCTAssertNil(metrics.headroomMinBytes)
    }

    func testUsbIgnoresBothSubmissionAndSendBufferPressure() {
        let generation = WirelessTransportPressure.reset(wireless: false)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 0,
            frameBytes: 1_000_000,
            nowNs: 100
        )
        XCTAssertNil(WirelessTransportPressure.noteForcedCapturePending())
        XCTAssertEqual(.normal, WirelessTransportPressure.captureAdmission(at: 101))
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
            availableBytes: 0,
            frameBytes: 500_000,
            nowNs: 100
        )

        let snapshot = WirelessTransportPressure.snapshotForTest()
        XCTAssertEqual(newGeneration, snapshot.generation)
        XCTAssertEqual(1, snapshot.sendsInFlight)
        XCTAssertNil(snapshot.availableSendBuffer)
        XCTAssertFalse(snapshot.forcedCapturePending)
        XCTAssertFalse(snapshot.largeSendOutstanding)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: 101))
    }
}
