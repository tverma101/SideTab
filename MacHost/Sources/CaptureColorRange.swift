import CoreVideo

/// Keep the wired SDR capture range aligned with the Android video compositor.
/// A full-range 420f buffer rendered as video range expands 16...235 to
/// 0...255, clipping dark and bright gradients. HDR conversion still takes
/// full-range 8-bit input, and the experimental 10-bit path is already video
/// range. Wireless keeps its existing capture format.
enum CaptureColorRange {
    static func pixelFormat(
        wireless: Bool,
        hdrConversion: Bool,
        experimental10Bit: Bool
    ) -> OSType {
        if experimental10Bit {
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return wireless || hdrConversion
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// Convert a full-range 8-bit luma sample to studio swing, rounding once.
    static func videoLuma(_ value: UInt8) -> UInt8 {
        UInt8(16 + (Int(value) * 219 + 127) / 255)
    }

    /// Convert full-range Cb/Cr to 16...240; neutral 128 stays neutral.
    static func videoChroma(_ value: UInt8) -> UInt8 {
        UInt8(16 + (Int(value) * 224 + 127) / 255)
    }
}
