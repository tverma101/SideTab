import CoreVideo
import Foundation

/// In-sender test-pattern injection (fork experiment harness) — RIG VALIDATION
/// ONLY. The offline harness (probes/offline_enc/) is the primary measurement
/// path; this exists so the one rig validation run shows known pixels.
///
/// Enabled by `SideScreen_exp_pattern` = "gradient" | "lowramp" | "stepped" |
/// "text" | "color". ONE static pattern per sender run (NOT a wall-clock
/// cycle): SCStream freezes when the display is idle and the keepalive
/// re-encodes the last frame, so the tablet shows a stable pattern the whole
/// run. Pattern math MUST stay in lockstep with harness fillY8/renderPatternSource
/// in probes/offline_enc/main.swift (they produce the reference source PNGs).
///
/// Format guard: 8-bit full/video-range biplanar buffers (2 planes,
/// interleaved CbCr) are supported — 10-bit biplanar buffers no-op with a log
/// line.
enum PatternInjector {
    static func isActive() -> Bool {
        UserDefaults.standard.string(forKey: "SideScreen_exp_pattern") != nil
    }

    static func fill(_ buffer: CVPixelBuffer) {
        let kind = UserDefaults.standard.string(forKey: "SideScreen_exp_pattern") ?? ""
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        guard VideoColorProfile.isSupportedEightBit420(fmt) else {
            debugLog("PatternInjector: format 0x\(String(fmt, radix: 16)) unsupported — skipping (10-bit path not supported on rig)")
            return
        }
        let fullRange = VideoColorProfile.isFullRange(fmt)

        // "file" mode: load a PNG (SideScreen_exp_patternFile) and blit it 1:1.
        // Used for the native-vs-stream chart A/B (2026-08-15).
        if kind == "file" {
            let path = UserDefaults.standard.string(forKey: "SideScreen_exp_patternFile") ?? ""
            guard !path.isEmpty, let rgb = loadPNG(path) else {
                debugLog("PatternInjector: file mode but no loadable PNG at '\(path)'")
                return
            }
            fillFromRGB(rgb, into: buffer, fullRange: fullRange)
            debugLog("PatternInjector: injected file \(path) (\(rgb.width)x\(rgb.height))")
            return
        }
        fillPattern(kind, buffer: buffer, base: base, fullRange: fullRange)
    }

    struct RGBImage { let width: Int; let height: Int; let pixels: [UInt8] } // RGBA

    static func loadPNG(_ path: String) -> RGBImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBImage(width: w, height: h, pixels: pixels)
    }

    /// Blit an RGBA image into an 8-bit 420 buffer (Y + interleaved CbCr), 1:1
    /// at the buffer's top-left; un-covered area stays as-is. Encode samples
    /// in the same range as the destination buffer.
    static func fillFromRGB(
        _ rgb: RGBImage,
        into buffer: CVPixelBuffer,
        fullRange: Bool = true
    ) {
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let w = min(rgb.width, bw), h = min(rgb.height, bh)
        for y in 0..<h {
            let yp = yBase + y * yRow
            let cp = cbCr + (y / 2) * cRow
            for x in 0..<w {
                let o = (y * rgb.width + x) * 4
                let r = rgb.pixels[o], g = rgb.pixels[o + 1], b = rgb.pixels[o + 2]
                let (yv, cb, cr) = ycbcr(r, g, b, fullRange: fullRange)
                yp.advanced(by: x).storeBytes(of: yv, as: UInt8.self)
                let cx = x / 2
                cp.advanced(by: cx * 2).storeBytes(of: cb, as: UInt8.self)
                cp.advanced(by: cx * 2 + 1).storeBytes(of: cr, as: UInt8.self)
            }
        }
    }

    static func fillPattern(
        _ kind: String,
        buffer: CVPixelBuffer,
        base: UnsafeMutableRawPointer,
        fullRange: Bool = true
    ) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let cbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cH = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)

        // ---- Y plane (identical math to harness fillY8) ----
        switch kind {
        case "gradient":
            for y in 0..<h {
                let v = UInt8(min(255, y * 255 / max(h - 1, 1)))
                memset(
                    base + y * yRow,
                    Int32(VideoColorProfile.encodeLuma(Double(v), fullRange: fullRange)),
                    w
                )
            }
        case "lowramp":
            for y in 0..<h {
                let v = UInt8(min(64, y * 64 / max(h - 1, 1)))
                memset(
                    base + y * yRow,
                    Int32(VideoColorProfile.encodeLuma(Double(v), fullRange: fullRange)),
                    w
                )
            }
        case "stepped":
            let patches = 17, ph = h / patches
            for i in 0..<patches {
                let v = VideoColorProfile.encodeLuma(Double(i * 8), fullRange: fullRange)
                for y in (i * ph)..<min((i + 1) * ph, h) {
                    memset(base + y * yRow, Int32(v), w)
                }
            }
        case "text":
            for y in 0..<h {
                let row = base + y * yRow
                let band = (y / 90) % 4
                for x in 0..<w {
                    let xb = x % 48
                    var v: UInt8 = 255
                    switch band {
                    case 0: if xb < 1 { v = 0 }
                    case 1: if xb < 2 { v = 0 }
                    case 2: if xb < 4 { v = 0 }
                    default: if xb < 8 { v = 0 }
                    }
                    if x % 7 == 0 && y % 7 == 0 { v = 0 }
                    row.advanced(by: x).storeBytes(
                        of: VideoColorProfile.encodeLuma(Double(v), fullRange: fullRange),
                        as: UInt8.self
                    )
                }
            }
        case "color":
            let cols = 6, rows = 4
            let pw = w / cols, ph = h / rows
            for i in 0..<colorPatches.count {
                let (y, _, _) = ycbcr(
                    colorPatches[i].0,
                    colorPatches[i].1,
                    colorPatches[i].2,
                    fullRange: fullRange
                )
                let cx = i % cols, cy = i / cols
                for yy in (cy * ph)..<min((cy + 1) * ph, h) {
                    memset(base + yy * yRow + cx * pw, Int32(y), pw)
                }
            }
        default:
            debugLog("PatternInjector: unknown pattern '\(kind)' — no-op")
            return
        }

        // ---- CbCr plane (interleaved, 4:2:0: 1 pair per 2x2 luma) ----
        if kind == "color" {
            let cols = 6, rows = 4
            let ph = h / rows
            let cpw = cw / cols, cph = cH / rows
            for i in 0..<colorPatches.count {
                let (_, cb, cr) = ycbcr(
                    colorPatches[i].0,
                    colorPatches[i].1,
                    colorPatches[i].2,
                    fullRange: fullRange
                )
                let cx = i % cols, cy = i / cols
                for yy in (cy * cph)..<min((cy + 1) * cph, cH) {
                    let row = cbCr + yy * cRow
                    for xx in 0..<cpw {
                        let off = (cx * cpw + xx) * 2
                        row.advanced(by: off).storeBytes(of: cb, as: UInt8.self)
                        row.advanced(by: off + 1).storeBytes(of: cr, as: UInt8.self)
                    }
                }
            }
        } else {
            memset(cbCr, 128, cRow * cH)
        }
        debugLog("PatternInjector: injected '\(kind)' \(w)x\(h)")
    }

    static let colorPatches: [(UInt8, UInt8, UInt8)] = [
        (255,255,255),(0,0,0),(255,0,0),(0,255,0),(0,0,255),(255,255,0),
        (0,255,255),(255,0,255),(245,222,179),(255,140,105),(135,206,250),(255,215,0),
        (64,64,64),(128,128,128),(192,192,192),(255,99,71),(60,179,113),(70,130,180),
        (255,182,193),(255,228,196),(176,224,230),(238,130,238),(255,160,122),(128,0,128),
    ]

    /// sRGB -> BT.709 YCbCr in the selected 8-bit range.
    static func ycbcr(
        _ r: UInt8,
        _ g: UInt8,
        _ b: UInt8,
        fullRange: Bool = true
    ) -> (UInt8, UInt8, UInt8) {
        let result = VideoColorProfile.ycbcr(
            red: r,
            green: g,
            blue: b,
            fullRange: fullRange
        )
        return (result.y, result.cb, result.cr)
    }
}
