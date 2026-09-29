import CoreVideo
import XCTest
@testable import SideScreen

/// Locks the dither contract: flat stays flat, ramps get sub-LSB noise, and the
/// amplitude gate is driven by the SOURCE gradient rather than by the noise the
/// pass itself injected.
final class DitherPassTests: XCTestCase {
    private let width = 256
    private let height = 64
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in ["SideScreen_exp_dither", "SideScreen_exp_ditherK", "SideScreen_exp_ditherBudget"] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(2, forKey: "SideScreen_exp_dither")      // ampMax 2 LSB
        UserDefaults.standard.set(5.5, forKey: "SideScreen_exp_ditherK")
        // These tests pin the amplitude contract, not the time box. At the
        // production 4 ms an unoptimised build on a CI VM stops at the row-32
        // budget check and leaves exactly half of the steep-ramp fixture
        // untouched (3136 of the 6272 pixels a full pass changes), which
        // reads as "not dithered". One second cannot truncate a 256x64 frame.
        UserDefaults.standard.set(1_000_000, forKey: "SideScreen_exp_ditherBudget")
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBuffer(fill: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let created = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(created, 0))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(created, 0)
        for row in 0..<height {
            for x in 0..<width {
                y[row * rowBytes + x] = fill(x, row)
            }
        }
        return created
    }

    private func luma(of buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        return plane[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]
    }

    // MARK: - Tests

    /// The contract at DitherPass's doc comment: "flat areas (range 0) -> NO
    /// noise". A pass that measures its gradient against the plane it is
    /// writing re-reads the noise it just injected, so the dither spreads
    /// through flat regions row by row until they carry a visible value set:
    /// measured on this fixture, the pre-fix pass dithered 62.5% of the pixels
    /// below the gradient band even though the source is uniform there.
    func testFlatRegionBelowAGradientIsUntouched() throws {
        // 0.25 LSB/px ramp on top, uniform below. Rows 32...39 are still inside
        // the 8px window of the band, so a real vertical gradient exists there
        // and dithering them is correct — rows 40 and below must be untouched.
        let buffer = try makeBuffer { x, y in y < 32 ? UInt8(60 + (x / 8) * 2) : 100 }
        XCTAssertTrue(DitherPass.apply(buffer))
        for y in 40..<height {
            for x in 0..<width {
                XCTAssertEqual(luma(of: buffer, x: x, y: y), 100, "flat pixel (\(x),\(y)) was dithered")
            }
        }
    }

    /// The flip side: the pass must still do its job on the ramp itself.
    func testGradientBandIsDithered() throws {
        let buffer = try makeBuffer { x, y in y < 32 ? UInt8(60 + (x / 8) * 2) : 100 }
        XCTAssertTrue(DitherPass.apply(buffer))
        var dithered = 0
        var bandPixels = 0
        for y in 0..<32 {
            for x in 0..<width {
                bandPixels += 1
                if luma(of: buffer, x: x, y: y) != UInt8(60 + (x / 8) * 2) { dithered += 1 }
            }
        }
        XCTAssertGreaterThan(dithered, bandPixels / 4, "the ramp must be dithered")
    }

    func testUniformFrameIsCompletelyUntouched() throws {
        let buffer = try makeBuffer { _, _ in 128 }
        XCTAssertTrue(DitherPass.apply(buffer))
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                XCTAssertEqual(luma(of: buffer, x: x, y: y), 128)
            }
        }
    }

    /// A 1-LSB-per-8px ramp is the banding case the pass exists for, and its
    /// slope-scaled amplitude stays under one LSB: the pass must not turn a
    /// near-flat ramp into visible grain.
    func testGentleRampGetsSubLsbAmplitude() throws {
        let buffer = try makeBuffer { x, _ in UInt8(min(255, 100 + x / 8)) }  // 1 LSB per 8px
        XCTAssertTrue(DitherPass.apply(buffer))
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let source = UInt8(min(255, 100 + x / 8))
                let delta = Int(luma(of: buffer, x: x, y: y)) - Int(source)
                XCTAssertLessThanOrEqual(abs(delta), 1, "ramp pixel (\(x),\(y)) moved by \(delta)")
                if delta != 0 { changed += 1 }
            }
        }
        XCTAssertLessThan(changed, width * height / 2, "sub-LSB amplitude should leave most pixels alone")
    }

    /// Steep edges are the only place the cap should bind, and even then the
    /// dither stays inside +/-ampMax.
    func testSteepGradientIsDitheredWithinTheAmplitudeCap() throws {
        let buffer = try makeBuffer { x, _ in UInt8(min(255, x * 2)) }  // 2 LSB/px
        XCTAssertTrue(DitherPass.apply(buffer))
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let source = UInt8(min(255, x * 2))
                let delta = Int(luma(of: buffer, x: x, y: y)) - Int(source)
                XCTAssertLessThanOrEqual(abs(delta), 2, "gradient pixel (\(x),\(y)) moved by \(delta)")
                if delta != 0 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, width * height / 4, "a 2 LSB/px ramp must be dithered")
    }

    func testUnsupportedFormatIsRejected() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let created = try XCTUnwrap(buffer)
        XCTAssertFalse(DitherPass.apply(created))
    }

    func testKnobBoundsAreSafe() {
        UserDefaults.standard.set(1_000_000, forKey: "SideScreen_exp_ditherK")
        XCTAssertLessThanOrEqual(DitherPass.kQ16, 4096)
        UserDefaults.standard.set(-4, forKey: "SideScreen_exp_ditherK")
        XCTAssertGreaterThanOrEqual(DitherPass.kQ16, 1)
    }
}
