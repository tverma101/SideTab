import XCTest
@testable import SideScreen

final class USBAdaptiveLoadControllerSimulationTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testMarginal120PathDoesNotPingPongRapidly() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 40, maxFPS: 120)

        var observed: [Int] = [controller.motionTargetFPS(maxFPS: 120, nowNs: 0)]
        func sample(_ tMs: UInt64) {
            let value = controller.motionTargetFPS(maxFPS: 120, nowNs: tMs * ms)
            if observed.last != value { observed.append(value) }
        }

        // Sustained sender backlog: fall quickly, but one level at a time.
        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 100 * ms)
        sample(100)
        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 200 * ms)
        sample(200)
        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 400 * ms)
        sample(400)
        XCTAssertEqual(observed, [120, 90, 60])

        // A burst of fast, fully drained sends is necessary but not sufficient;
        // the pressure-free timer must also expire before probing upward.
        for i in 0..<20 {
            controller.observeSendCompletion(
                generation: 40,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (500 + UInt64(i) * 50) * ms
            )
        }
        sample(1_900)
        XCTAssertEqual(observed, [120, 90, 60])
        sample(2_500)
        XCTAssertEqual(observed, [120, 90, 60, 90])

        for i in 0..<20 {
            controller.observeSendCompletion(
                generation: 40,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (2_600 + UInt64(i) * 50) * ms
            )
        }
        sample(7_400)
        XCTAssertEqual(observed, [120, 90, 60, 90])
        sample(7_600)
        XCTAssertEqual(observed, [120, 90, 60, 90, 120])

        // If the 120 probe fails almost immediately, record a penalty. The
        // cooldown prevents two same-burst samples from causing a double step.
        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 7_700 * ms)
        sample(7_700)
        XCTAssertEqual(observed.last, 120)
        XCTAssertEqual(controller.snapshotForTest().rampPenalty, 1)

        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 7_900 * ms)
        sample(7_900)
        XCTAssertEqual(observed.last, 90)

        controller.observeSendsInFlight(generation: 40, count: 3, nowNs: 8_200 * ms)
        sample(8_200)
        XCTAssertEqual(observed.last, 60)

        // No oscillation: the next 60 -> 90 probe now needs the penalty-adjusted
        // four-second quiet period instead of the original two seconds.
        for i in 0..<20 {
            controller.observeSendCompletion(
                generation: 40,
                durationNs: 2 * ms,
                sendsInFlightAfter: 0,
                nowNs: (8_300 + UInt64(i) * 50) * ms
            )
        }
        sample(12_000)
        XCTAssertEqual(observed.last, 60)
        sample(12_300)
        XCTAssertEqual(observed.last, 90)
    }
}
