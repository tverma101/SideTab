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

    func testUsbNeverBackpressuresEncoderThroughWirelessGate() {
        let generation = WirelessTransportPressure.reset(wireless: false)
        WirelessTransportPressure.setReady(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        WirelessTransportPressure.beginSend(generation: generation)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
    }

    func testLateCompletionCannotAlterReplacementGeneration() {
        let oldGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: oldGeneration)
        WirelessTransportPressure.beginSend(generation: oldGeneration)
        WirelessTransportPressure.beginSend(generation: oldGeneration)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        WirelessTransportPressure.beginSend(generation: newGeneration)
        WirelessTransportPressure.completeSend(generation: oldGeneration)

        let snapshot = WirelessTransportPressure.snapshotForTest()
        XCTAssertEqual(newGeneration, snapshot.generation)
        XCTAssertEqual(1, snapshot.sendsInFlight)
        XCTAssertFalse(WirelessTransportPressure.shouldPauseEncoding)
    }
}
