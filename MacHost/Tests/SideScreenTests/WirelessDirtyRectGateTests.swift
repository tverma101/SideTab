import CoreGraphics
import XCTest
@testable import SideScreen

final class WirelessDirtyRectGateTests: XCTestCase {
    func testSkipsOnlyExplicitlyCleanWirelessFrames() {
        XCTAssertTrue(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: true,
                mutatesCapturedPixels: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: nil,
                mutatesCapturedPixels: false
            )
        )
    }

    func testNeverSkipsUsbOrSyntheticPixelMutation() {
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: false,
                frameHasChanges: false,
                mutatesCapturedPixels: false
            )
        )
        XCTAssertFalse(
            WirelessDirtyRectGate.shouldSkip(
                wireless: true,
                frameHasChanges: false,
                mutatesCapturedPixels: true
            )
        )
    }
}
