import CoreVideo
import XCTest
@testable import SideScreen

final class VideoColorProfileTests: XCTestCase {
    func testDefaultCaptureFormatIsEightBitVideoRange() {
        let defaults = UserDefaults(suiteName: "VideoColorProfileTests")!
        defaults.removePersistentDomain(forName: "VideoColorProfileTests")
        defer { defaults.removePersistentDomain(forName: "VideoColorProfileTests") }

        XCTAssertEqual(
            VideoColorProfile.configuredCapturePixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testExplicitControlsPreserveFullAndTenBitRanges() {
        let defaults = UserDefaults(suiteName: "VideoColorProfileControlsTests")!
        defaults.removePersistentDomain(forName: "VideoColorProfileControlsTests")
        defer { defaults.removePersistentDomain(forName: "VideoColorProfileControlsTests") }

        defaults.set("8bit", forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            VideoColorProfile.configuredCapturePixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        defaults.set("10bit", forKey: "SideScreen_exp_pixelFormat")
        XCTAssertEqual(
            VideoColorProfile.configuredCapturePixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            VideoColorProfile.fallbackCapturePixelFormat(defaults: defaults),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testVideoRangeMapsBlackWhiteAndNeutralChroma() {
        let black = VideoColorProfile.ycbcr(red: 0, green: 0, blue: 0, fullRange: false)
        XCTAssertEqual(black.y, 16)
        XCTAssertEqual(black.cb, 128)
        XCTAssertEqual(black.cr, 128)

        let white = VideoColorProfile.ycbcr(red: 255, green: 255, blue: 255, fullRange: false)
        XCTAssertEqual(white.y, 235)
        XCTAssertEqual(white.cb, 128)
        XCTAssertEqual(white.cr, 128)
    }

    func testRangeNamesMakeTheLiveCaptureChoiceAuditable() {
        XCTAssertEqual(
            VideoColorProfile.rangeName(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            "8-bit video"
        )
        XCTAssertEqual(
            VideoColorProfile.rangeName(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            "8-bit full"
        )
    }
}
