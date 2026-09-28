import CoreVideo
import XCTest
@testable import SideScreen

final class WiredColorRangeTests: XCTestCase {
    func testWiredSDRUsesVideoRangeAcrossCapturePaths() {
        XCTAssertEqual(
            CaptureColorRange.pixelFormat(wireless: false, hdrConversion: false, experimental10Bit: false),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            CaptureColorRange.pixelFormat(wireless: true, hdrConversion: false, experimental10Bit: false),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(
            CaptureColorRange.pixelFormat(wireless: false, hdrConversion: true, experimental10Bit: false),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(
            CaptureColorRange.pixelFormat(wireless: false, hdrConversion: false, experimental10Bit: true),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    }

    func testVideoRangeConversionPreservesFullRampWithoutClipping() {
        XCTAssertEqual(CaptureColorRange.videoLuma(0), 16)
        XCTAssertEqual(CaptureColorRange.videoLuma(255), 235)
        XCTAssertEqual(CaptureColorRange.videoChroma(0), 16)
        XCTAssertEqual(CaptureColorRange.videoChroma(128), 128)
        XCTAssertEqual(CaptureColorRange.videoChroma(255), 240)

        for value in 0...255 {
            let encodedY = Int(CaptureColorRange.videoLuma(UInt8(value)))
            let encodedC = Int(CaptureColorRange.videoChroma(UInt8(value)))
            let displayedY = ((encodedY - 16) * 255 + 109) / 219
            let displayedC = ((encodedC - 16) * 255 + 112) / 224
            XCTAssertLessThanOrEqual(abs(displayedY - value), 1, "luma \(value)")
            XCTAssertLessThanOrEqual(abs(displayedC - value), 1, "chroma \(value)")
            if value > 0 {
                XCTAssertGreaterThanOrEqual(encodedY, Int(CaptureColorRange.videoLuma(UInt8(value - 1))))
            }
        }
    }

    func testInjectedColorChartAndGradientUseVideoRangeSamples() throws {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 12, 256,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &optionalBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        PatternInjector.fillPattern("color", buffer: buffer, base: yBase, videoRange: true)
        XCTAssertEqual(yBase.load(as: UInt8.self), 235) // white
        XCTAssertEqual(yBase.advanced(by: 2).load(as: UInt8.self), 16) // black
        XCTAssertEqual(uvBase.load(as: UInt8.self), 128) // neutral Cb
        XCTAssertEqual(uvBase.advanced(by: 1).load(as: UInt8.self), 128) // neutral Cr

        PatternInjector.fillPattern("gradient", buffer: buffer, base: yBase, videoRange: true)
        XCTAssertEqual(yBase.load(as: UInt8.self), 16)
        XCTAssertEqual(yBase.advanced(by: 255 * yStride).load(as: UInt8.self), 235)
        XCTAssertEqual(yBase.advanced(by: 64 * yStride).load(as: UInt8.self), CaptureColorRange.videoLuma(64))
    }
}
