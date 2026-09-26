import XCTest
@testable import SideScreen

final class CodecLimitsTests: XCTestCase {
    /// Relative aspect tolerance for a clamped result. Only the binding axis can
    /// be exact; the derived axis carries up to half a macroblock of error,
    /// which is 0.4% at ~1088 px and proportionally larger on a short derived
    /// axis — see CodecLimits.clamp.
    private let aspectTolerance = 0.01

    private func assertAspectPreserved(
        _ input: (width: Int, height: Int),
        _ output: (width: Int, height: Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let aspectIn = Double(input.width) / Double(input.height)
        let aspectOut = Double(output.width) / Double(output.height)
        let relativeError = abs(aspectOut - aspectIn) / aspectIn
        XCTAssertLessThan(
            relativeError, aspectTolerance,
            "\(input.width)x\(input.height) -> \(output.width)x\(output.height) aspect error \(relativeError)",
            file: file, line: line
        )
    }

    func testBooxPanelClampsToFitAvcLimit() {
        // Boox Nova Air C panel: 1872x1404 (4:3). AVC HW decoder max: 1920x1088.
        // Height binds; 1088 is 16-aligned, and 4:3 of 1088 is 1450.67, which
        // rounds to the NEAREST macroblock (1456) rather than truncating to 1440.
        let r = CodecLimits.clampForAvc(width: 1872, height: 1404)
        XCTAssertEqual(r.width, 1456)
        XCTAssertEqual(r.height, 1088)
        assertAspectPreserved((1872, 1404), (r.width, r.height))
    }

    func testSizeWithinLimitIsUntouched() {
        let r = CodecLimits.clampForAvc(width: 1920, height: 1080)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1080)
    }

    func testWideHiDpiPanelClamps() {
        // 2560x1600 (16:10): height is the binding constraint (1088/1600).
        let r = CodecLimits.clampForAvc(width: 2560, height: 1600)
        XCTAssertEqual(r.width, 1744)
        XCTAssertEqual(r.height, 1088)
        assertAspectPreserved((2560, 1600), (r.width, r.height))
    }

    func testWidthBindingClampDoesNotLosePixelsToTruncation() {
        // 2148x800: width binds (scale = 1920/2148). Without rounding,
        // Int(2148 * 1920/2148) truncates to 1919 -> 1904. Expect 1920.
        let r = CodecLimits.clampForAvc(width: 2148, height: 800)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 720)
        assertAspectPreserved((2148, 800), (r.width, r.height))
    }

    func testSmallPanelUntouched() {
        let r = CodecLimits.clampForAvc(width: 1280, height: 800)
        XCTAssertEqual(r.width, 1280)
        XCTAssertEqual(r.height, 800)
    }

    func testClampedDimensionsAre16AlignedAndEven() {
        // Inputs that actually need clamping. Sizes already inside the cap pass
        // through untouched, alignment included (see testSizeWithinLimitIsUntouched).
        for (w, h) in [(3840, 2400), (2800, 1752), (2732, 2732), (2731, 1501), (1921, 1081)] {
            let r = CodecLimits.clampForAvc(width: w, height: h)
            XCTAssertEqual(r.width % 16, 0, "\(w)x\(h) -> \(r.width)x\(r.height)")
            XCTAssertEqual(r.height % 16, 0, "\(w)x\(h) -> \(r.width)x\(r.height)")
            XCTAssertEqual(r.width % 2, 0)
            XCTAssertEqual(r.height % 2, 0)
            XCTAssertLessThanOrEqual(r.width, 1920)
            XCTAssertLessThanOrEqual(r.height, 1088)
        }
    }

    /// The regression this suite exists for: per-axis rounding squashed every
    /// clamped stream (0.74% narrow on the Boox panel). Assert the error stays
    /// inside half a macroblock of the derived axis across the panel sizes this
    /// project actually ships.
    func testClampNeverSquashesAspectBeyondMacroblockError() {
        let panels = [(1872, 1404), (2560, 1600), (2800, 1752), (2400, 1440), (3840, 2400), (1366, 768)]
        for (w, h) in panels {
            let r = CodecLimits.clampForAvc(width: w, height: h)
            let aspectIn = Double(w) / Double(h)
            let aspectOut = Double(r.width) / Double(r.height)
            let relativeError = abs(aspectOut - aspectIn) / aspectIn
            XCTAssertLessThan(relativeError, aspectTolerance, "\(w)x\(h) -> \(r.width)x\(r.height) error \(relativeError)")
        }
    }

    // MARK: - Client decoder limit clamp (issue #41)

    func testHiDpiStreamClampsToClientDecoderLimit() {
        // rm2109cmyk's case: 1200x720 HiDPI = 2400x1440 physical, budget
        // tablet decoder caps around 2048x1152.
        let r = CodecLimits.clamp(width: 2400, height: 1440, maxWidth: 2048, maxHeight: 1152)
        XCTAssertLessThanOrEqual(r.width, 2048)
        XCTAssertLessThanOrEqual(r.height, 1152)
        XCTAssertEqual(r.width % 16, 0)
        XCTAssertEqual(r.height % 16, 0)
        assertAspectPreserved((2400, 1440), (r.width, r.height))
    }

    func testStreamWithinClientLimitIsUntouched() {
        let r = CodecLimits.clamp(width: 1920, height: 1200, maxWidth: 4096, maxHeight: 2304)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1200)
    }

    func testClientLimitPreservesAspectRatio() {
        let r = CodecLimits.clamp(width: 3840, height: 2400, maxWidth: 1920, maxHeight: 1080)
        // 16:10 in, 16:10 out to well inside half a macroblock.
        assertAspectPreserved((3840, 2400), (r.width, r.height))
        XCTAssertLessThanOrEqual(r.width, 1920)
        XCTAssertLessThanOrEqual(r.height, 1080)
    }

    func testSquareCapStillFitsAndKeepsAspectWhenOnlyOneAxisBinds() {
        // 1920x1920 box over a 16:10 source: height is not the binding axis, so
        // 16:10 is preserved exactly inside the box.
        let r = CodecLimits.clamp(width: 3840, height: 2400, maxWidth: 1920, maxHeight: 1920)
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 1200)
    }

    func testClampIsIdempotent() {
        // A clamp result must be a fixed point: re-clamping (which happens when
        // a client renegotiates after a codec switch) must not keep shrinking.
        for (w, h) in [(1872, 1404), (2560, 1600), (2800, 1752), (3840, 2400)] {
            let once = CodecLimits.clampForAvc(width: w, height: h)
            let twice = CodecLimits.clampForAvc(width: once.width, height: once.height)
            XCTAssertEqual(once.width, twice.width)
            XCTAssertEqual(once.height, twice.height)
        }
    }

    func testDegenerateInputsDoNotTrapOrInvert() {
        let zero = CodecLimits.clamp(width: 0, height: 0, maxWidth: 1920, maxHeight: 1088)
        XCTAssertEqual(zero.width, 0)
        XCTAssertEqual(zero.height, 0)

        let tinyCap = CodecLimits.clamp(width: 1920, height: 1080, maxWidth: 8, maxHeight: 8)
        XCTAssertGreaterThanOrEqual(tinyCap.width, 16)
        XCTAssertGreaterThanOrEqual(tinyCap.height, 16)
    }
}
