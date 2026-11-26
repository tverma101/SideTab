import XCTest
@testable import SideScreen

final class HostLifecycleControllerTests: XCTestCase {
    func testWakeWhileStillLockedDoesNotResumePixels() {
        let controller = HostLifecycleController()

        controller.beginSuspend(.sessionInactive)
        controller.beginSuspend(.systemSleep)
        controller.suspendCompleted()

        XCTAssertFalse(controller.mayEmitDesktopPixels)
        XCTAssertEqual(
            controller.state,
            .suspended([.sessionInactive, .systemSleep])
        )

        controller.clearSuspendReason(.systemSleep)

        XCTAssertFalse(controller.mayEmitDesktopPixels)
        XCTAssertEqual(controller.state, .suspended([.sessionInactive]))

        controller.clearSuspendReason(.sessionInactive)
        XCTAssertEqual(controller.state, .resuming)
        XCTAssertFalse(controller.mayEmitDesktopPixels)

        controller.resumeCompleted()
        XCTAssertEqual(controller.state, .active)
        XCTAssertTrue(controller.mayEmitDesktopPixels)
    }

    func testLateResumeCompletionCannotBeatNewSuspendReason() {
        let controller = HostLifecycleController()

        controller.beginSuspend(.screenSaver)
        controller.suspendCompleted()
        controller.clearSuspendReason(.screenSaver)
        XCTAssertEqual(controller.state, .resuming)

        controller.beginSuspend(.sessionInactive)
        controller.resumeCompleted()

        XCTAssertEqual(controller.state, .suspended([.sessionInactive]))
        XCTAssertFalse(controller.mayEmitDesktopPixels)
    }

    func testDuplicateSuspendReasonIsIdempotent() {
        let controller = HostLifecycleController()

        XCTAssertTrue(controller.beginSuspend(.displaySleep))
        XCTAssertFalse(controller.beginSuspend(.displaySleep))
        XCTAssertEqual(controller.suspendReasons, [.displaySleep])
        XCTAssertEqual(controller.state, .suspending([.displaySleep]))
    }

    func testSuspendReasonsHaveStableWireIDs() {
        XCTAssertEqual(HostSuspendReason.sessionInactive.wireID, 1)
        XCTAssertEqual(HostSuspendReason.screenSaver.wireID, 2)
        XCTAssertEqual(HostSuspendReason.displaySleep.wireID, 3)
        XCTAssertEqual(HostSuspendReason.systemSleep.wireID, 4)
    }
}
