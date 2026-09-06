import XCTest
@testable import SideScreen

final class WirelessTransportAdaptationTests: XCTestCase {
    private func feedWindow(
        generation: UInt64,
        pressured: Bool,
        startNs: UInt64
    ) -> UInt64 {
        var now = startNs
        for _ in 0..<120 {
            WirelessTransportPressure.observeSendBuffer(
                generation: generation,
                availableBytes: pressured ? 32 * 1024 : 512 * 1024,
                frameBytes: 64 * 1024,
                nowNs: now
            )
            _ = WirelessTransportPressure.captureAdmission(at: now + 1)
            WirelessTransportPressure.beginSend(generation: generation, nowNs: now + 2)
            WirelessTransportPressure.completeSend(generation: generation, nowNs: now + 12_002)
            now += 100_000_000
        }
        return now
    }

    func testTwoPressureTelemetryWindowsRecommendOneBitrateStepDown() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)

        var now: UInt64 = 1_000_000_000
        now = feedWindow(generation: generation, pressured: true, startNs: now)
        XCTAssertEqual(0, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)

        now = feedWindow(generation: generation, pressured: true, startNs: now)
        let state = WirelessTransportPressure.encodingState(at: now + 100_000_000)
        XCTAssertFalse(state.pause)
        XCTAssertEqual(1, state.bitrateStepDown)
    }

    func testHealthyWindowsRecoverRecommendedBitrateSlowly() {
        let generation = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: generation)

        var now: UInt64 = 10_000_000_000
        now = feedWindow(generation: generation, pressured: true, startNs: now)
        now = feedWindow(generation: generation, pressured: true, startNs: now)
        XCTAssertEqual(1, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)

        for _ in 0..<4 {
            now = feedWindow(generation: generation, pressured: false, startNs: now)
            XCTAssertEqual(1, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)
        }
        now = feedWindow(generation: generation, pressured: false, startNs: now)
        XCTAssertEqual(0, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)
    }

    func testReplacementTransportRestoresFullRateRecommendation() {
        let oldGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: oldGeneration)

        var now: UInt64 = 20_000_000_000
        now = feedWindow(generation: oldGeneration, pressured: true, startNs: now)
        now = feedWindow(generation: oldGeneration, pressured: true, startNs: now)
        XCTAssertEqual(1, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)

        let newGeneration = WirelessTransportPressure.reset(wireless: true)
        WirelessTransportPressure.setReady(generation: newGeneration)
        XCTAssertEqual(0, WirelessTransportPressure.encodingState(at: now).bitrateStepDown)
    }

    func testUsbNeverProducesBitrateRecommendation() {
        let generation = WirelessTransportPressure.reset(wireless: false)
        WirelessTransportPressure.setReady(generation: generation)
        let state = WirelessTransportPressure.encodingState(at: 1_000)
        XCTAssertFalse(state.pause)
        XCTAssertEqual(0, state.bitrateStepDown)
    }
}
