import CoreGraphics
import XCTest
@testable import SideScreen

final class WirelessDirtyRectGateTests: XCTestCase {
    func testSkipsOnlyExplicitlyCleanWirelessFramesUnderNormalAdmission() {
        XCTAssertTrue(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                captureAdmission: .normal
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: true,
                mutatesCapturedPixels: false,
                captureAdmission: .normal
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: nil,
                mutatesCapturedPixels: false,
                captureAdmission: .normal
            )
        )
    }

    func testPauseAdmissionSkipsRoutineWirelessCaptureBeforePixelWork() {
        XCTAssertTrue(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: true,
                mutatesCapturedPixels: true,
                captureAdmission: .pause
            )
        )
    }

    func testForcedAdmissionBypassesPressureAndDirtyRectGate() {
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                captureAdmission: .forced
            )
        )
    }

    func testNeverSkipsUsbOrSyntheticPixelMutationUnderNormalAdmission() {
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: false,
                frameHasChanges: false,
                mutatesCapturedPixels: false,
                captureAdmission: .pause
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: true,
                captureAdmission: .normal
            )
        )
    }
}
