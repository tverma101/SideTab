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

        // Socket headroom is healthy, so the only pressure source is the frame
        // itself. A 300 KiB IDR/motion burst should not be followed immediately
        // by another routine encode while that large send is outstanding.
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

        // There is technically room for this 64 KiB frame now, but sending it
        // would leave only 16 KiB. Stop before encoding another dependent frame.
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

        // 120 KiB available can hold the current 64 KiB frame, but leaves only
        // 56 KiB. The old fixed 32 KiB reserve would admit more work here; the
        // new policy preserves room for roughly one comparable next frame.
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

        // A delayed encode from the retired transport cannot consume the new
        // session's recovery admission.
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
