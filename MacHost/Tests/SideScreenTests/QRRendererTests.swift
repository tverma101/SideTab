import XCTest
import CoreGraphics
@testable import SideScreen

final class QRRendererTests: XCTestCase {
    private let url = "sidescreen://192.168.1.42:54321?t=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&name=Mac"

    private func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let decoded: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return decoded ? buffer : nil
    }

    func testRendersASquareRaster() throws {
        let image = try XCTUnwrap(QRRenderer.renderCGImage(url: url, size: 180))
        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThan(image.width, QRRenderer.quietZoneModules * 2)
    }

    /// CIQRCodeGenerator emits no quiet zone, and a code without one is not
    /// reliably decodable — the white margin is the renderer's job.
    func testQuietZoneIsBakedInAsWhite() throws {
        let image = try XCTUnwrap(QRRenderer.renderCGImage(url: url, size: 180))
        let buffer = try XCTUnwrap(pixels(image))
        for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
            XCTAssertEqual(buffer[y * image.width + x], 255, "corner (\(x),\(y)) must be quiet zone")
        }
        XCTAssertTrue(buffer.contains { $0 == 0 }, "the code itself must contain dark modules")
    }

    /// Modules must land on whole pixels: a fractional scale gives neighbouring
    /// modules different widths, and the first resample that touches it with
    /// anything but nearest-neighbour smears the code.
    func testModulesAreWholePixels() throws {
        let image = try XCTUnwrap(QRRenderer.renderCGImage(url: url, size: 180))
        let buffer = try XCTUnwrap(pixels(image))
        let y = image.height / 2
        let row = Array(buffer[y * image.width..<(y + 1) * image.width])
        var runs: [Int] = []
        var current = 1
        for index in 1..<row.count {
            if row[index] == row[index - 1] {
                current += 1
            } else {
                runs.append(current)
                current = 1
            }
        }
        runs.append(current)
        let module = try XCTUnwrap(runs.min())
        XCTAssertGreaterThan(module, 0)
        for run in runs {
            XCTAssertEqual(run % module, 0, "run of \(run) px is not a whole number of \(module) px modules")
        }
    }

    func testTinyAndHugeSizesDoNotTrap() {
        for size in [1.0, 4.0, 10.0, 22.0, 4096.0] as [CGFloat] {
            XCTAssertNotNil(QRRenderer.renderCGImage(url: url, size: size), "size \(size) must render")
        }
        XCTAssertNil(QRRenderer.renderCGImage(url: url, size: 0))
        XCTAssertNil(QRRenderer.renderCGImage(url: url, size: -10))
    }

    func testPayloadTooLargeForAnyVersionIsHandledNotTrapped() {
        let huge = String(repeating: "A", count: 8000)
        let built = PairingURL.build(host: "192.168.1.42", port: 54321, token: Data(repeating: 1, count: 32), name: huge)
        guard let built else { return XCTFail("expected a payload") }
        // No QR version holds 8 kB, so the encoder has to bail out rather than
        // produce something unservable. Either way it must not trap.
        if let image = QRRenderer.renderCGImage(url: built, size: 180) {
            XCTAssertEqual(image.width, image.height)
        }
    }

    func testDeterministicForTheSamePayload() throws {
        let first = try XCTUnwrap(QRRenderer.renderCGImage(url: url, size: 180))
        let second = try XCTUnwrap(QRRenderer.renderCGImage(url: url, size: 180))
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(pixels(first), pixels(second))
    }

    func testRenderWrapsTheRasterAtTheRequestedPointSize() throws {
        let image = try XCTUnwrap(QRRenderer.render(url: url, size: 180))
        XCTAssertEqual(image.size.width, 180)
        XCTAssertEqual(image.size.height, 180)
        XCTAssertNil(QRRenderer.render(url: url, size: 0))
    }
}
