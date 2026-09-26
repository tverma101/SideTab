import Foundation
import CoreVideo

/// DitherPass — slope-adaptive blue-noise (Bayer 8x8) dithering for the
/// 8-bit Y plane of the 4:2:0 capture buffer. EXPERIMENT-FORK ONLY.
///
/// Goal: break the step structure the tablet's video path re-quantizes into
/// visible banding (R1: 256 source levels collapse to ~98 with 2.8-step
/// jumps). Adding sub-visible blue noise before encode decorrelates the
/// tablet's per-pixel rounding: hard steps become mixed-level noise the eye
/// integrates as smooth.
///
/// Amplitude gating (the "engineered, not vibecoded" part):
///   A(x,y) = min(ampMax, (localRange/8) * k) — localRange is the 8px-window
///   difference in 8-bit LSB, so (localRange/8) is the local SLOPE in LSB/px.
///   - flat areas (range 0)  -> NO noise (grain-free surfaces)
///   - 1-LSB ramps           -> sub-LSB amplitude
///   - steep edges           -> capped at ampMax (invisible on high contrast)
/// The amplitude is measured against an UNMUTATED copy of the source rows:
/// measuring against the plane being written re-reads the noise this pass just
/// injected, so a flat region manufactures its own local contrast and fills in
/// with a visible value set — a direct violation of the contract above.
/// Static pattern -> no temporal shimmer. Offline-validated by the D-series
/// harness experiments (plateau collapse 17.8->2.8/1.5 post-Q98).
///
/// Knobs: SideScreen_exp_dither = 1|2 (ampMax in 8-bit LSB units; 0 = off)
///        SideScreen_exp_ditherK = 5.5 (default)
enum DitherPass {
    static let bayer: [Int] = [
        0, 48, 12, 60, 3, 51, 15, 63,
        32, 16, 44, 28, 35, 19, 47, 31,
        8, 56, 4, 52, 11, 59, 7, 55,
        40, 24, 36, 20, 43, 27, 39, 23,
        2, 50, 14, 62, 1, 49, 13, 61,
        34, 18, 46, 30, 33, 17, 45, 29,
        10, 58, 6, 54, 9, 57, 5, 53,
        42, 26, 38, 22, 41, 25, 37, 21,
    ]

    /// Window of the local-gradient estimate, in pixels. Also the divisor that
    /// turns an 8px LSB difference into a slope in LSB/px.
    private static let windowPx = 8

    /// Pristine source rows kept in a ring so the vertical half of the gradient
    /// never sees already-dithered pixels. Must be a power of two.
    private static let sourceRingRows = 8

    static var enabled: Bool {
        UserDefaults.standard.integer(forKey: "SideScreen_exp_dither") > 0
    }

    /// Amplitude cap in 8-bit LSB units, bounded by the container so the
    /// fixed-point noise multiply below cannot overflow.
    static var ampMax: Int {
        min(255, max(1, UserDefaults.standard.integer(forKey: "SideScreen_exp_dither")))
    }

    /// Slope gain, fixed point in 1/16 LSB units per LSB/px. Bounded so a typo
    /// in the knob cannot overflow the multiply.
    static var kQ16: Int {
        let k = UserDefaults.standard.double(forKey: "SideScreen_exp_ditherK")
        return min(4096, max(1, Int((k > 0 ? k : 5.5) * 16)))
    }

    /// Per-frame CPU budget (µs). Photo/video frames are the worst case for
    /// the per-pixel pass but banding is invisible there (noise-masked), so
    /// partial coverage is free perceptually. The stop row depends on content
    /// AND machine load, so the dithered band's lower edge can move between
    /// frames — a moving horizontal seam. Inside the dithered region the pattern
    /// is static, so there is no temporal shimmer; the moving edge is why this
    /// pass stays experiment-only.
    static var budgetUs: Int {
        let b = UserDefaults.standard.integer(forKey: "SideScreen_exp_ditherBudget")
        return b > 0 ? b : 4000
    }

    /// In-place dither of the Y plane. Returns false when the buffer format
    /// is not an 8-bit 4:2:0 biplanar (format guard, like PatternInjector).
    @discardableResult
    static func apply(_ buf: CVPixelBuffer) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(buf)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return false
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return false }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let p = yb.assumingMemoryBound(to: UInt8.self)
        let ampMaxQ = ampMax * 16
        let kQ = kQ16
        let b = bayer
        let budgetNs = Int64(budgetUs) * 1000
        let t0 = Int64(DispatchTime.now().uptimeNanoseconds)
        // Row padding is never read (x < w) and never snapshotted.
        var sourceRing = [UInt8](repeating: 0, count: sourceRingRows * w)
        var ampRow = [Int](repeating: 0, count: w)

        for y in 0..<h {
            if y & 31 == 0 && DispatchTime.now().uptimeNanoseconds - UInt64(t0) > UInt64(budgetNs) {
                break  // time-boxed: photo frames degrade gracefully, no drops
            }
            let row = y * rowBytes
            let y8 = max(0, y - windowPx) * rowBytes
            let byRow = (y & 7) * 8
            // Row pre-check: sample both axes at 8 columns. All-zero => flat
            // row (the common UI case) -> skip in ~µs. A miss only means the
            // row pays the full per-pixel pass (never an artifact).
            var rowFlat = true
            for s in 0..<8 {
                let sx = (s * 2 + 1) * w / 16
                if Int(p[row + sx]) - Int(p[row + max(0, sx - windowPx)]) != 0
                    || Int(p[row + sx]) - Int(p[y8 + sx]) != 0 {
                    rowFlat = false
                    break
                }
            }
            if rowFlat { continue }

            // Pass 1 — amplitudes, from the source only. Slot `y & 7` still
            // holds row y-8's pristine samples, because rows are snapshotted
            // after they are measured and before they are written.
            let ringBase = (y & (sourceRingRows - 1)) * w
            for x in 0..<w {
                let v = Int(p[row + x])
                let vx = Int(p[row + max(0, x - windowPx)])
                let vy = y >= windowPx ? Int(sourceRing[ringBase + x]) : v
                let dx = abs(v - vx)
                let dy = abs(v - vy)
                let range = dx > dy ? dx : dy
                let ampQ = min((range * kQ) / windowPx, ampMaxQ)
                ampRow[x] = ampQ
            }
            for x in 0..<w {
                sourceRing[ringBase + x] = p[row + x]
            }

            // Pass 2 — apply. Each pixel is still pristine when it is read, and
            // the amplitude depends on nothing this pass writes.
            for x in 0..<w {
                let ampQ = ampRow[x]
                if ampQ == 0 { continue }  // flat: no noise
                let v = Int(p[row + x])
                // noise = amp * (bayer/31.5 - 1)  in 1/16-LSB fixed point:
                //   nQ = ampQ * (b*2 - 63);  noise_LSB = nQ / (16 * 63)
                //   exact divisor 1008; approximated by *65>>16 (0.02% error)
                let nQ = ampQ * (b[byRow + (x & 7)] * 2 - 63)
                var nv = v + ((nQ * 65 + 32768) >> 16)  // round-to-nearest
                if nv < 0 { nv = 0 } else if nv > 255 { nv = 255 }
                p[row + x] = UInt8(nv)
            }
        }
        return true
    }
}
