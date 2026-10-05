import XCTest
@testable import SideScreen

final class USBAdaptiveReconfigurationTests: XCTestCase {
    func testChangingSourceCeilingResetsLearnedLadder() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 21, maxFPS: 120)

        controller.observeSendsInFlight(generation: 21, count: 3, nowNs: 100_000_000)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 100_000_000), 90)

        // User changes the stream setting while the same TCP/ADB connection is
        // alive. The old 120-Hz pressure history must not leak into the new cap.
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 90, nowNs: 200_000_000), 90)
        var snapshot = controller.snapshotForTest()
        XCTAssertEqual(snapshot.maxFPS, 90)
        XCTAssertEqual(snapshot.targetFPS, 90)
        XCTAssertEqual(snapshot.rampPenalty, 0)

        // Raising the ceiling later starts a fresh 120-Hz probe instead of
        // remaining stuck at the previous 60/90 decision.
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 120, nowNs: 300_000_000), 120)
        snapshot = controller.snapshotForTest()
        XCTAssertEqual(snapshot.maxFPS, 120)
        XCTAssertEqual(snapshot.targetFPS, 120)
    }

    func testDroppingToSixtyDisablesMotionAdaptation() {
        let controller = USBAdaptiveLoadController()
        controller.reset(generation: 22, maxFPS: 120)
        XCTAssertEqual(controller.motionTargetFPS(maxFPS: 60, nowNs: 1), 60)
        XCTAssertFalse(controller.snapshotForTest().active)
    }
}
