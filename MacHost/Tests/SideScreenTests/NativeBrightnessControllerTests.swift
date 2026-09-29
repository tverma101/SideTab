import XCTest
@testable import SideScreen

final class NativeBrightnessControllerTests: XCTestCase {
    func testClampsToRecoverablePanelRange() {
        XCTAssertEqual(NativeBrightnessController.clampedLevel(-10), 8)
        XCTAssertEqual(NativeBrightnessController.clampedLevel(8), 8)
        XCTAssertEqual(NativeBrightnessController.clampedLevel(128), 128)
        XCTAssertEqual(NativeBrightnessController.clampedLevel(300), 255)
    }

    func testNormalizedConversionRoundTrips() {
        let level = NativeBrightnessController.level(forNormalizedValue: 0.5)
        XCTAssertEqual(level, 128)
        XCTAssertEqual(NativeBrightnessController.normalizedValue(for: level), 128.0 / 255.0, accuracy: 0.0001)
    }
}
