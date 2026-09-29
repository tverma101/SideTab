import CoreVideo
import XCTest
@testable import SideScreen

/// Locks the HDR transfer-function contract: a PQ container is full 0..1023,
/// SDR white lands on 100 nits, and the two planes use one range convention.
final class HDRConverterTests: XCTestCase {
    /// ST 2084 EOTF, the exact inverse of HDRConverter.pqSignal.
    private func pqNits(_ signal: Double) -> Double {
        let m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0
        let c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0
        let e = pow(signal, 1.0 / m2)
        let num = max(e - c1, 0.0)
        let den = c2 - e * c3
        guard den > 0 else { return .infinity }
        return 10_000.0 * pow(num / den, 1.0 / m1)
    }

    private func nits(forLumaCode code: Int) -> Double {
        pqNits(Double(HDRConverter.pqLumaCode(code: code, sourceFullRange: false)) / 1023.0)
    }

    // MARK: - Luma

    func testVideoBlackIsZeroNits() {
        // The studio floor (code 16) is below-black by definition, so the
        // expanded signal is 0 and PQ code 0 is 0 nits — not the 15.9 nits the
        // old 64..940 window produced.
        XCTAssertEqual(HDRConverter.pqLumaCode(code: 16, sourceFullRange: false), 0)
        XCTAssertEqual(nits(forLumaCode: 16), 0, accuracy: 0.001)
    }

    func testVideoWhiteIs100Nits() {
        // The regression: the old mapping emitted code 922 for 8-bit 235, which
        // decodes to 3952 nits — a 39x over-bright white document.
        let code = HDRConverter.pqLumaCode(code: 235, sourceFullRange: false)
        XCTAssertEqual(code, 520, "SDR white is PQ code 520 (100 nits), not the 64..940 gamma window")
        XCTAssertEqual(nits(forLumaCode: 235), 100, accuracy: 0.5)
    }

    func testMidGreyIsAbout20Nits() {
        // 8-bit 128 is 0.2 relative luminance, i.e. 20 nits with SDR white at
        // 100 — the BT.2408 mid-grey placement.
        let code = HDRConverter.pqLumaCode(code: 128, sourceFullRange: false)
        XCTAssertEqual(nits(forLumaCode: 128), 20, accuracy: 0.3)
        XCTAssertTrue((360...370).contains(code), "unexpected mid-grey code \(code)")
    }

    func testFullRangeSourceUsesTheSameWhitePoint() {
        XCTAssertEqual(HDRConverter.pqLumaCode(code: 255, sourceFullRange: true), 520)
        XCTAssertEqual(HDRConverter.pqLumaCode(code: 0, sourceFullRange: true), 0)
    }

    func testVideoRangeSourceClampsBelowBlackAndAboveWhite() {
        XCTAssertEqual(HDRConverter.pqLumaCode(code: 0, sourceFullRange: false), 0)
        XCTAssertEqual(HDRConverter.pqLumaCode(code: 255, sourceFullRange: false), 520)
    }

    func testLumaMappingIsMonotonicAndInContainer() {
        var previous = -1
        for code in 0...255 {
            let mapped = HDRConverter.pqLumaCode(code: code, sourceFullRange: false)
            XCTAssertTrue((0...1023).contains(mapped), "code \(mapped) out of container")
            XCTAssertGreaterThanOrEqual(mapped, previous, "not monotonic at \(code)")
            previous = mapped
        }
    }

    /// PQ spreads the SDR range across the container instead of the 64..940
    /// gamma window, so 8-bit levels stay distinguishable after the tablet
    /// re-quantizes. The old window left only 876 codes for 256 levels.
    func testLumaMappingKeepsMostOfTheContainerUsable() {
        let mapped = (0...255).map { HDRConverter.pqLumaCode(code: $0, sourceFullRange: false) }
        let span = (mapped.max() ?? 0) - (mapped.min() ?? 0)
        XCTAssertGreaterThan(span, 500, "SDR range collapsed into \(span) codes")
        XCTAssertGreaterThanOrEqual(Set(mapped).count, 200)
    }

    func testAdjacentLumaCodesStayDistinguishable() {
        // 1-LSB steps must not collapse: a neighbouring pair has to differ.
        for code in 16...234 {
            let a = HDRConverter.pqLumaCode(code: code, sourceFullRange: false)
            let b = HDRConverter.pqLumaCode(code: code + 1, sourceFullRange: false)
            XCTAssertGreaterThan(b, a, "codes \(code)/\(code + 1) collapsed to \(a)")
        }
    }

    // MARK: - Chroma

    func testChromaIsFullRangeWithNeutralAt512() {
        // The old comment claimed "10-bit video range" while the math produced
        // 0..1020 (full range), disagreeing with the luma plane. Both planes are
        // full range now, and chroma keeps the conventional 4x upshift.
        XCTAssertEqual(HDRConverter.pqChromaCode(code: 128), 512)
        XCTAssertEqual(HDRConverter.pqChromaCode(code: 0), 0)
        XCTAssertEqual(HDRConverter.pqChromaCode(code: 255), 1020)
    }

    func testChromaIsSymmetricAroundNeutral() {
        for delta in 1...127 {
            let below = HDRConverter.pqChromaCode(code: 128 - delta)
            let above = HDRConverter.pqChromaCode(code: 128 + delta)
            XCTAssertEqual(above - 512, 512 - below, "chroma not symmetric at ±\(delta)")
        }
    }

    // MARK: - Signalling contract

    func testPQIsNotSignalledWhenHDRIsDisabled() {
        XCTAssertFalse(HDRConverter.isTenBitPQActive(width: 1920, height: 1080))
    }
}
