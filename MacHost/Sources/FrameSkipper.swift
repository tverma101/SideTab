import Foundation
import CoreVideo
import CryptoKit

/// FrameSkipper — SANDBOX-ONLY (efficiency audit Entry T, Lever 1). NOT
/// deployed to production or exp_bin.
///
/// Problem: on a static screen the pipeline encodes + tunnels + decodes +
/// presents ~55 pixel-identical frames per second (measured: 2.2 Mbps of
/// churn, tablet decode burn, bursty presents).
///
/// This gate hash-compares each captured frame against the last SENT frame
/// and skips encode+send when nothing changed:
///   - static screen  -> ~1 encode per keepalive interval (default 1.5s)
///   - content change -> full rate resumes instantly (hash mismatch)
///   - client connect -> forceNextFrame() (paired with encoder keyframe
///     request) guarantees the next frame goes out as an IDR
///
/// Hash: even-stride sampling of the Y plane (every 8th px/row) + CbCr plane
/// (every 8th byte/row) — ~91KB sampled for 2800×1752, FNV-1a 64, ~µs.
///
/// Knobs: SideScreen_exp_skipFrames = 1 (default 0 = off)
///        SideScreen_exp_skipKeepaliveMs = 1500 (default)
enum FrameSkipper {
    struct Decision {
        let skip: Bool
        let hash: UInt64
    }

    private static var lastHash: UInt64 = 0
    private static var lastSendNs: UInt64 = 0
    private static var forceNext = false
    private static let lock = NSLock()

    static var enabled: Bool {
        UserDefaults.standard.integer(forKey: "SideScreen_exp_skipFrames") > 0
    }

    static var keepaliveNs: UInt64 {
        let ms = UserDefaults.standard.integer(forKey: "SideScreen_exp_skipKeepaliveMs")
        return UInt64(ms > 0 ? ms : 1500) * 1_000_000
    }

    /// Force the next frame through (call alongside encoder.requestKeyframe()).
    static func forceNextFrame() {
        lock.lock(); defer { lock.unlock() }
        forceNext = true
    }

    /// Full-plane SHA-256 of the Y + CbCr planes (every byte → ANY change is
    /// detected; sparse sampling was rejected in sandbox tests: it missed
    /// single-row/single-pixel changes). HW-accelerated (~1-2ms at 2800×1752).
    static func hash(_ buf: CVPixelBuffer) -> UInt64 {
        var hasher = SHA256()
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
            let hh = CVPixelBufferGetHeight(buf)
            let rb = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            hasher.update(data: Data(bytes: y, count: rb * hh))
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
            let ch = CVPixelBufferGetHeightOfPlane(buf, 1)
            let rb = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            hasher.update(data: Data(bytes: c, count: rb * ch))
        }
        let digest = hasher.finalize()
        return digest.withUnsafeBytes { $0.load(as: UInt64.self) }
    }

    /// Decision: true = skip this frame (identical content, keepalive not
    /// due, no force pending). Call on the capture thread.
    static func decide(_ buf: CVPixelBuffer) -> Decision {
        let now = DispatchTime.now().uptimeNanoseconds
        let h = hash(buf)
        lock.lock(); defer { lock.unlock() }
        if forceNext { return Decision(skip: false, hash: h) }
        if h != lastHash { return Decision(skip: false, hash: h) }
        if now - lastSendNs >= keepaliveNs { return Decision(skip: false, hash: h) }
        return Decision(skip: true, hash: h)
    }

    /// Record that a frame with this hash was handed to the encoder.
    static func noteSent(hash h: UInt64) {
        lock.lock(); defer { lock.unlock() }
        lastHash = h
        lastSendNs = DispatchTime.now().uptimeNanoseconds
        forceNext = false
    }

    /// Test hook: reset state between scenarios.
    static func resetForTest() {
        lock.lock(); defer { lock.unlock() }
        lastHash = 0
        lastSendNs = 0
        forceNext = false
    }
}
