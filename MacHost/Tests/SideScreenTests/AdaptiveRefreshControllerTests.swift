import CoreGraphics
import XCTest
@testable import SideScreen

final class AdaptiveRefreshControllerTests: XCTestCase {
    func testPointerWakeIsScopedToCapturedDisplayBounds() {
        let bounds = CGRect(x: -1400, y: 204, width: 1400, height: 876)

        XCTAssertTrue(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: -700, y: 600),
                displayBounds: bounds
            )
        )
        XCTAssertFalse(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: 300, y: 600),
                displayBounds: bounds
            )
        )
        XCTAssertFalse(
            AdaptiveRefreshController.isPointerInsideCapturedDisplay(
                CGPoint(x: -700, y: 600),
                displayBounds: nil
            )
        )
    }
}
