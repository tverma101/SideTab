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
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 20_000_000))
    }

    func testFrameThatWouldConsumeTcpReservePausesNextEncode() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)
        let now: UInt64 = 1_500_000_000

        // There is technically room for this 64 KiB frame now, but sending it
        // would leave only 16 KiB. The encoder should stop before producing the
        // next dependent frame instead of discovering the near-full socket one
        // frame too late.
        WirelessTransportPressure.observeSendBuffer(
            generation: generation,
            availableBytes: 80 * 1024,
            frameBytes: 64 * 1024,
            nowNs: now
        )

        XCTAssertTrue(WirelessTransportPressure.shouldPauseEncoding(at: now + 1))
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: now + 20_000_000))
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
        XCTAssertTrue(WirelessTransportPressure.forcedCapturePending)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        let newMarker = WirelessTransportPressure.noteForcedCapturePending()
        XCTAssertEqual(newGeneration, newMarker)
        XCTAssertTrue(WirelessTransportPressure.forcedCapturePending)

        // A delayed encode from the retired transport cannot consume the new
        // session's recovery admission.
        WirelessTransportPressure.clearForcedCapturePending(generation: oldGeneration)
        XCTAssertTrue(WirelessTransportPressure.forcedCapturePending)

        WirelessTransportPressure.clearForcedCapturePending(generation: newGeneration)
        XCTAssertFalse(WirelessTransportPressure.forcedCapturePending)
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
        XCTAssertFalse(WirelessTransportPressure.forcedCapturePending)
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
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding(at: 101))
    }
}
