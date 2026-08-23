import Foundation
import CoreVideo

// FrameSkipper unit tests (sandbox). Compile: swiftc -O FrameSkipper.swift test_frameskip.swift
func debugLog(_ msg: String) {  // stub matching AppDelegate's debugLog
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    print((cond ? "PASS: " : "FAIL: ") + name)
    if !cond { failures += 1 }
}

func makeBuffer(fill: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferWidthKey: 2800,
        kCVPixelBufferHeightKey: 1752,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, 2800, 1752,
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        attrs as CFDictionary, &buf)
    let b = buf!
    CVPixelBufferLockBaseAddress(b, [])
    let yb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    let p = yb.assumingMemoryBound(to: UInt8.self)
    for y in 0..<1752 {
        for x in 0..<2800 { p[y * yRow + x] = fill(x, y) }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

// Static UI-like frame (flat + one text row) vs variants
let base = makeBuffer { x, y in (y == 500 && x % 6 < 2) ? 0 : 200 }
let same = makeBuffer { x, y in (y == 500 && x % 6 < 2) ? 0 : 200 }
let changedY = makeBuffer { x, y in (y == 500 && x % 6 < 2) ? 0 : (y == 501 ? 180 : 200) }
let changedChroma = makeBuffer { x, y in (y == 500 && x % 6 < 2) ? 0 : 200 }
let onePixel = makeBuffer { x, y in (y == 500 && x % 6 < 2) ? 0 : ((x == 1373 && y == 877) ? 7 : 200) }

// chroma variant: same Y, different Cb (lock around the write)
CVPixelBufferLockBaseAddress(changedChroma, [])
let cb = CVPixelBufferGetBaseAddressOfPlane(changedChroma, 1)!
let cbRow = CVPixelBufferGetBytesPerRowOfPlane(changedChroma, 1)
let cp = cb.assumingMemoryBound(to: UInt8.self)
cp[100 * cbRow + 100] = 90  // single chroma sample change
CVPixelBufferUnlockBaseAddress(changedChroma, [])

UserDefaults.standard.set(80, forKey: "SideScreen_exp_skipKeepaliveMs")  // fast keepalive for tests
UserDefaults.standard.set(1, forKey: "SideScreen_exp_skipFrames")

// 1. identical frames: first sends, second skips
FrameSkipper.resetForTest()
var d1 = FrameSkipper.decide(base)
expect(!d1.skip, "first frame sends (hash \(d1.hash))")
FrameSkipper.noteSent(hash: d1.hash)
d1 = FrameSkipper.decide(same)
expect(d1.skip, "identical frame skips")
expect(d1.hash == FrameSkipper.hash(base), "identical frames hash equal")

// 2. changed Y → sends
d1 = FrameSkipper.decide(changedY)
expect(!d1.skip, "changed-luma frame sends")
FrameSkipper.noteSent(hash: d1.hash)

// 3. changed chroma → sends (sampling covers CbCr)
d1 = FrameSkipper.decide(changedChroma)
expect(!d1.skip, "changed-chroma frame sends")
FrameSkipper.noteSent(hash: d1.hash)

// 4. keepalive: identical frame sends after interval
// (re-establish same-content baseline: base != last sent chroma frame)
d1 = FrameSkipper.decide(same)
expect(!d1.skip, "content change vs last sent → sends")
FrameSkipper.noteSent(hash: d1.hash)
d1 = FrameSkipper.decide(same)
expect(d1.skip, "identical skips before keepalive due")
usleep(120_000)  // > 80ms keepalive
d1 = FrameSkipper.decide(same)
expect(!d1.skip, "identical sends when keepalive due")
FrameSkipper.noteSent(hash: d1.hash)

// 5. forceNextFrame: identical sends immediately
d1 = FrameSkipper.decide(same)
expect(d1.skip, "identical skips again")
FrameSkipper.forceNextFrame()
d1 = FrameSkipper.decide(same)
expect(!d1.skip, "forceNextFrame forces send")
FrameSkipper.noteSent(hash: d1.hash)

// 6. force clears after noteSent
d1 = FrameSkipper.decide(same)
expect(d1.skip, "force consumed by the forced send")

// 7. hash sanity: different content → different hashes
expect(FrameSkipper.hash(base) != FrameSkipper.hash(changedY), "distinct frames hash differently")
expect(FrameSkipper.hash(base) != FrameSkipper.hash(onePixel), "single-pixel change detected")

// 8. timing: hash cost on full-res buffer
let t0 = DispatchTime.now().uptimeNanoseconds
var hh: UInt64 = 0
for _ in 0..<20 { hh = FrameSkipper.hash(base) }
let perHash = Double(DispatchTime.now().uptimeNanoseconds - t0) / 20 / 1e6
print(String(format: "INFO: hash cost %.3f ms/frame (2800x1752)", perHash))

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TESTS FAILED")
exit(failures == 0 ? 0 : 1)
