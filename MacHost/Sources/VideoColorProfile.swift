import CoreVideo
import Foundation

/// Shared capture-range contract for the macOS sender.
///
/// Android's hardware decoder uses the video-range conversion for the normal
/// SDR path. Capture 8-bit frames as video-range by default so the pixel
/// buffer, VideoToolbox VUI, and Android presentation agree. The full-range
/// value remains an explicit A/B experiment, not the production default.
enum VideoColorProfile {
    static func configuredCapturePixelFormat(defaults: UserDefaults = .standard) -> OSType {
        switch defaults.string(forKey: "SideScreen_exp_pixelFormat") {
        case "10bit":
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case "8bitVideo", nil:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        default:
            // The legacy "8bit" value is the full-range control. Keeping
            // unknown non-empty values on that side preserves old A/B runs.
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    /// CGDisplayStream fallback is currently 8-bit only; preserve the
    /// requested 8-bit range and avoid asking it for a 10-bit surface.
    static func fallbackCapturePixelFormat(defaults: UserDefaults = .standard) -> OSType {
        let configured = configuredCapturePixelFormat(defaults: defaults)
        return configured == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : configured
    }

    static func isFullRange(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func isSupportedEightBit420(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    static func rangeName(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return "10-bit video"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "8-bit video"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "8-bit full"
        default:
            return "unknown (0x\(String(pixelFormat, radix: 16)))"
        }
    }

    static func encodeLuma(_ value: Double, fullRange: Bool) -> UInt8 {
        let encoded = fullRange ? value : 16.0 + value * 219.0 / 255.0
        return UInt8(min(max(encoded.rounded(), 0), 255))
    }

    static func encodeChroma(_ value: Double, fullRange: Bool) -> UInt8 {
        let encoded = fullRange ? value : 16.0 + value * 224.0 / 255.0
        return UInt8(min(max(encoded.rounded(), 0), 255))
    }

    /// Convert an sRGB sample to BT.709 YCbCr in the selected 8-bit range.
    static func ycbcr(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        fullRange: Bool
    ) -> (y: UInt8, cb: UInt8, cr: UInt8) {
        let rf = Double(red)
        let gf = Double(green)
        let bf = Double(blue)
        let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
        let cb = -0.1146 * rf - 0.3854 * gf + 0.5 * bf + 128.0
        let cr = 0.5 * rf - 0.4542 * gf - 0.0458 * bf + 128.0
        return (
            encodeLuma(y, fullRange: fullRange),
            encodeChroma(cb, fullRange: fullRange),
            encodeChroma(cr, fullRange: fullRange)
        )
    }
}
