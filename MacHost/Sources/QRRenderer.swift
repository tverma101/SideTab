import Foundation
import CoreImage
import CoreGraphics
import AppKit

enum QRRenderer {
    /// "M" recovers ~15% of the code. The level is part of the payload contract
    /// with the scanner, and dropping to "L" only buys a sparser code that then
    /// has to fit the same box.
    static let correctionLevel = "M"
    /// ISO/IEC 18004 minimum. CIQRCodeGenerator emits no quiet zone at all, and
    /// a code without one is not reliably decodable — the quiet zone is baked
    /// into the raster here rather than left to whatever sits behind the image.
    static let quietZoneModules = 4

    /// One context for the process: building one costs tens of milliseconds,
    /// and rendering with it is safe from any thread.
    private static let context = CIContext()

    /// Renders the given pairing URL as a QR code NSImage of the requested side length (in points).
    /// Returns nil if encoding fails.
    static func render(url: String, size: CGFloat = 220) -> NSImage? {
        guard let raster = renderCGImage(url: url, size: size) else { return nil }
        return NSImage(cgImage: raster, size: NSSize(width: size, height: size))
    }

    /// The rasterised code. Rendering to a bitmap rather than handing back an
    /// `NSCIImageRep` means CoreImage does the work once: the rep form is lazy
    /// and re-rasterises on every draw.
    ///
    /// Scaled by a whole number of pixels per module on purpose. A fractional
    /// scale leaves some modules a pixel wider than their neighbours, and the
    /// first resample that touches it with anything other than
    /// nearest-neighbour smears a QR into something that will not scan.
    static func renderCGImage(url: String, size: CGFloat = 220) -> CGImage? {
        guard size > 0,
              let data = url.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let generated = filter.outputImage else { return nil }

        let moduleCount = max(1, Int(generated.extent.width.rounded()))
        let totalModules = moduleCount + quietZoneModules * 2
        // Rounded down, so the view only ever magnifies this raster. Scaling up
        // in AppKit would drop module rows and lose real detail.
        let pixelsPerModule = max(1, Int(size / CGFloat(totalModules)))
        let side = pixelsPerModule * totalModules
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let inset = quietZoneModules * pixelsPerModule

        let code = generated
            .transformed(by: CGAffineTransform(scaleX: CGFloat(pixelsPerModule), y: CGFloat(pixelsPerModule)))
            .transformed(by: CGAffineTransform(translationX: CGFloat(inset), y: CGFloat(inset)))
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)

        return context.createCGImage(code.composited(over: background), from: bounds)
    }
}
