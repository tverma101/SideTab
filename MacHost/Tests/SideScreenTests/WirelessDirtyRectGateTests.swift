import CoreGraphics
import XCTest
@testable import SideScreen

final class WirelessDirtyRectGateTests: XCTestCase {
    func testSkipsOnlyExplicitlyCleanWirelessFramesWithoutPressure() {
        XCTAssertTrue(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                transportPressured: false,
                forcedCapturePending: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: true,
                mutatesCapturedPixels: false,
                transportPressured: false,
                forcedCapturePending: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: nil,
                mutatesCapturedPixels: false,
                transportPressured: false,
                forcedCapturePending: false
            )
        )
    }

    func testTransportPressureSkipsRoutineWirelessCaptureBeforePixelWork() {
        XCTAssertTrue(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: true,
                mutatesCapturedPixels: true,
                transportPressured: true,
                forcedCapturePending: false
            )
        )
    }

    func testForcedRecoveryFrameBypassesPressureAndDirtyRectGate() {
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                transportPressured: true,
                forcedCapturePending: true
            )
        )
    }

    func testNeverSkipsUsbOrSyntheticPixelMutationWithoutPressure() {
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: false,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                transportPressured: true,
                forcedCapturePending: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: true,
                transportPressured: false,
                forcedCapturePending: false
            )
        )
    }
}
