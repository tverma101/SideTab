import XCTest
@testable import SideScreen

final class USBAdaptiveRecoveryPulseTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testTwoRecoveryPulsesDoNotDownshift() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 31, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        controller.observeRecoveryPulse(nowNs: 350 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 350 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().recoveryPulseCount, 2)
    }

    func testThirdRecoveryPulseInsideOneSecondDownshiftsOneTier() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 32, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        controller.observeRecoveryPulse(nowNs: 350 * ms)
        controller.observeRecoveryPulse(nowNs: 600 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 600 * ms), 90)
        XCTAssertEqual(controller.snapshotForTest().recoveryPulseCount, 0)
    }

    func testSpacedRecoveryPulsesNeverAccumulateIntoPressure() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 33, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        controller.observeRecoveryPulse(nowNs: 1_200 * ms)
        controller.observeRecoveryPulse(nowNs: 2_300 * ms)
        controller.observeRecoveryPulse(nowNs: 3_400 * ms)

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 3_400 * ms), 120)
        XCTAssertEqual(controller.snapshotForTest().recoveryPulseCount, 1)
    }

    func testSustainedRecoveryBurstsCanStep120To90Then60() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 34, maxFPS: 120)

        controller.observeRecoveryPulse(nowNs: 100 * ms)
        controller.observeRecoveryPulse(nowNs: 300 * ms)
        controller.observeRecoveryPulse(nowNs: 500 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 500 * ms), 90)

        // Fresh evidence after the controller's 250 ms downshift cooldown.
        controller.observeRecoveryPulse(nowNs: 800 * ms)
        controller.observeRecoveryPulse(nowNs: 1_000 * ms)
        controller.observeRecoveryPulse(nowNs: 1_200 * ms)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 1_200 * ms), 60)
    }

    func testRecoveryPulsesAreIgnoredAtSixtyFPS() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 35, maxFPS: 60)

        for i in 0..<6 {
            controller.observeRecoveryPulse(nowNs: UInt64(100 + i * 100) * ms)
        }

        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 60, nowNs: 700 * ms), 60)
        XCTAssertEqual(controller.snapshotForTest().recoveryPulseCount, 0)
    }
}
