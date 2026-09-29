import Accelerate
import CoreVideo
import Foundation

/// EXP-FORK: live 8-bit SDR capture -> 10-bit PQ/BT.2020 HDR-converted frames.
///
/// Why: the S8+ panel is 10-bit HDR10+; an 8-bit SDR stream caps gradients at
/// 256 levels and composites at 8-bit. Encoding 10-bit PQ-flagged BT.2020
/// (VUI via kVTCompressionPropertyKey_* in VideoEncoder, SideScreen_exp_hdr)
/// makes the tablet's HDR path engage, giving ~4x the luma levels on the
/// panel — the real fix for AMOLED gradient banding.
///
/// Container convention: BOTH planes are FULL range over the whole 10-bit
/// container. For a PQ transfer characteristic the 10-bit code IS the PQ
/// signal, so it spans 0..1023 with no 64..940 head/tail reserve; 64..940 is
/// the BT.2020 *gamma* luma swing and only applies to a non-PQ transfer
/// function. Luma is therefore not a 4x upshift of the 8-bit code (it is
/// PQ-encoded), while chroma is — chroma is a signed distance from neutral that
/// no transfer function touches, so it keeps the conventional 4x upshift with
/// neutral at 512.
///
/// Conversion (8-bit SDR -> 10-bit PQ):
///   Y: expand the studio swing for the source range -> de-gamma (2.4) ->
///      scale so SDR white is 100 nits = 100/10000 of the PQ normalisation ->
///      PQ -> 0..1023, via a 256-entry UInt16 LUT (vImageLookupTable_Planar8toPlanar16).
///   Cb/Cr: 8-bit -> 10-bit 4x upshift, neutral 128 -> 512, same LUT mechanism.
///   BT.709->BT.2020 matrix is approximated (small delta for SDR content).
///
/// Enabled by `SideScreen_exp_hdr=1` (must pair with VideoEncoder's HDR VUI
/// block and Main10 profile).
enum HDRConverter {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr") }

    /// SDR reference white. `pow(e, 2.4)` yields linear 0..1 with 1.0 == diffuse
    /// white, but ST 2084 normalises its input to 10,000 nits, so the SDR range
    /// has to be divided into the PQ normalisation explicitly — otherwise every
    /// pixel is placed as if the brightest one were peak-nit.
    static let sdrReferenceWhiteNits = 100.0
    static let pqPeakNits = 10_000.0

    /// Buffer geometry the pool was built for. `unbuilt` means convert() has not
    /// been asked for a size yet (it builds on demand); `unavailable` means a
    /// build was attempted and every allocation failed, in which case the
    /// encoder must not declare the PQ VUI.
    enum PoolGeometry: Equatable {
        case unbuilt
        case sized(width: Int, height: Int)
        case unavailable
    }

    /// CVPixelBuffer is a CF type the compiler refuses to treat as Sendable. A
    /// pool buffer is written only by the capture queue and read only by
    /// VideoToolbox, and it only leaves the free list when no lease holds it —
    /// the ordering the lease provides is exactly what the conformance claims.
    private struct PoolBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    private struct Lease {
        let buffer: PoolBuffer
        let startedNs: UInt64
    }

    private struct PoolState {
        var geometry: PoolGeometry = .unbuilt
        var free: [PoolBuffer] = []
        var leases: [UInt64: Lease] = [:]
        var nextLeaseID: UInt64 = 1
        /// Buffers dropped by a geometry change while VideoToolbox may still be
        /// reading them. They are released after the drain window, not at once.
        var retired: [(buffer: PoolBuffer, retiredNs: UInt64)] = []
        var skippedFrames: UInt64 = 0
    }

    /// A lease is only handed back by the VideoToolbox output callback. If the
    /// encoder is torn down without draining, the callback never runs and the
    /// buffer would stay in flight forever, so stale leases are reclaimed well
    /// past any encode latency.
    private static let leaseDrainNs: UInt64 = 2_000_000_000

    /// Immutable once built, so it can be published to the capture queue without
    /// holding the lock across the conversion itself.
    private final class LookupTables: @unchecked Sendable {
        let luma: [UInt16]
        let chroma: [UInt16]
        /// Which source range they were built for. The tables are
        /// size-independent but NOT range-independent.
        let sourceFullRange: Bool

        init(sourceFullRange: Bool) {
            var luma = [UInt16](repeating: 0, count: 256)
            var chroma = [UInt16](repeating: 0, count: 256)
            for i in 0..<256 {
                luma[i] = UInt16(HDRConverter.pqLumaCode(code: i, sourceFullRange: sourceFullRange) << 6)
                chroma[i] = UInt16(HDRConverter.pqChromaCode(code: i) << 6)
            }
            self.luma = luma
            self.chroma = chroma
            self.sourceFullRange = sourceFullRange
        }
    }

    /// 10-bit biplanar surfaces cost 3 B/px (16-bit Y + 8-bit CbCr), so depth 4
    /// is 12 B/px of source. Deep enough to cover encoder latency without
    /// turning a 2800x1752 session into ~90 MB of HDR pool.
    private static let poolDepth = 4

    private static let lutLock = OSAllocatedUnfairLock<LookupTables?>(initialState: nil)
    private static let poolLock = OSAllocatedUnfairLock(initialState: PoolState())

    // MARK: - Transfer function

    /// BT.2020 PQ OETF: linear (0..1 = 0..10,000 nits) -> PQ signal (0..1).
    static func pqSignal(_ lin: Double) -> Double {
        let m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0
        let c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0
        let y = pow(lin, m1)
        return pow((c1 + c2 * y) / (1.0 + c3 * y), m2)
    }

    /// 8-bit luma code -> 10-bit PQ code (0..1023).
    /// `sourceFullRange` mirrors the capture format: the production capture is
    /// VIDEO range (VideoColorProfile.configuredCapturePixelFormat), so codes
    /// outside 16..235 are below black / above white and are clamped.
    static func pqLumaCode(code: Int, sourceFullRange: Bool) -> Int {
        let expanded = sourceFullRange
            ? Double(code) / 255.0
            : (Double(code) - 16.0) / 219.0
        let linear = pow(min(1.0, max(0.0, expanded)), 2.4)
        let normalised = linear * (sdrReferenceWhiteNits / pqPeakNits)
        let signal = pqSignal(normalised)
        return min(1023, max(0, Int((signal * 1023.0).rounded())))
    }

    /// 8-bit chroma code -> 10-bit code, full range, neutral 128 -> 512.
    static func pqChromaCode(code: Int) -> Int {
        min(1023, max(0, Int((512.0 + (Double(code) - 128.0) * 4.0).rounded())))
    }

    // MARK: - Signalling contract

    /// True when a 10-bit PQ buffer is genuinely what convert() will hand to
    /// the encoder for `width`x`height` sources. VideoEncoder consults this
    /// before writing the PQ/BT.2020 VUI and pinning Main10: signalling PQ while
    /// 8-bit SDR frames are encoded makes the receiver apply EOTF_PQ to SDR
    /// data (a washed-out/black screen), and it is unrecoverable until the
    /// session is rebuilt.
    ///
    /// A stale pool size still reports true because convert() resizes the pool
    /// on demand; a pool whose allocation failed reports false.
    static func isTenBitPQActive(width: Int, height: Int) -> Bool {
        guard enabled else { return false }
        switch poolLock.withLock({ $0.geometry }) {
        case .unbuilt:
            return true
        case .unavailable:
            debugLog("HDRConverter: pool allocation failed — not signalling PQ/10-bit")
            return false
        case let .sized(w, h):
            if w == width && h == height { return true }
            debugLog("HDRConverter: pool is \(w)x\(h), session is \(width)x\(height) — first frame resizes it")
            return true
        }
    }

    // MARK: - Setup

    /// Warm the LUTs and size the pool. The LUTs are size-independent and are
    /// built once; the pool is NOT size-independent, so it is rebuilt whenever
    /// the requested geometry differs from the current pool's geometry.
    static func ensureSetup(width: Int, height: Int) {
        buildLUTsIfNeeded()
        let geometry: PoolGeometry? = poolLock.withLock { state -> PoolGeometry? in
            pruneRetired(&state)
            if state.geometry == .sized(width: width, height: height) { return nil }
            rebuildPool(&state, width: width, height: height)
            return state.geometry
        }
        if let geometry {
            debugLog("HDRConverter: pool \(width)x\(height) (\(geometry)), LUTs ready")
        }
    }

    private static func buildLUTsIfNeeded() {
        let sourceFullRange = VideoColorProfile.isFullRange(
            VideoColorProfile.configuredCapturePixelFormat()
        )
        let rebuilt: Bool = lutLock.withLock { tables -> Bool in
            guard tables?.sourceFullRange != sourceFullRange else { return false }
            tables = LookupTables(sourceFullRange: sourceFullRange)
            return true
        }
        if rebuilt {
            debugLog("HDRConverter: LUTs built (source range: \(sourceFullRange ? "full" : "video"))")
        }
    }

    /// 10-bit buffers are IOSurface-backed like the capture buffers so the HW
    /// encoder stays on its preferred path.
    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attrs as CFDictionary, &buf
        )
        guard st == kCVReturnSuccess else { return nil }
        return buf
    }

    /// Replaces the pool. Buffers that were leased are retired rather than
    /// dropped: a retained pixel buffer is not mutation-stable, but it IS still
    /// owned by VideoToolbox until the output callback runs, and freeing the
    /// IOSurface under a running encoder is exactly the hazard this pass exists
    /// to prevent.
    private static func rebuildPool(_ state: inout PoolState, width: Int, height: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        for lease in state.leases.values {
            state.retired.append((buffer: lease.buffer, retiredNs: now))
        }
        state.leases.removeAll()
        state.free.removeAll()

        var built: [PoolBuffer] = []
        for _ in 0..<poolDepth {
            if let buffer = makeBuffer(width: width, height: height) {
                built.append(PoolBuffer(value: buffer))
            }
        }
        state.geometry = built.isEmpty ? .unavailable : .sized(width: width, height: height)
        state.free = built
        if built.isEmpty {
            debugLog("HDRConverter: could not allocate \(width)x\(height) 10-bit buffers")
        }
    }

    private static func pruneRetired(_ state: inout PoolState) {
        let now = DispatchTime.now().uptimeNanoseconds
        state.retired.removeAll { now &- $0.retiredNs > leaseDrainNs }
    }

    // MARK: - Leases

    /// Hands out a buffer that no pending encode is reading. Retaining the
    /// pixel buffer is NOT what keeps it stable — the free list is; a
    /// rotating index over a fixed pool recycles a surface while VideoToolbox
    /// is still reading it, which tears the frame horizontally.
    private static func acquire(width: Int, height: Int) -> (leaseID: UInt64, buffer: CVPixelBuffer)? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let leased = poolLock.withLock({ state -> (UInt64, PoolBuffer)? in
            pruneRetired(&state)

            if state.geometry != .sized(width: width, height: height) {
                rebuildPool(&state, width: width, height: height)
            }
            // A lease whose output callback never arrived (session invalidated
            // mid-flight) would otherwise wedge the pool permanently.
            let expired = state.leases.filter { now &- $0.value.startedNs > leaseDrainNs }
            for (id, lease) in expired {
                state.leases.removeValue(forKey: id)
                state.free.append(lease.buffer)
            }
            if !expired.isEmpty {
                debugLog("HDRConverter: reclaimed \(expired.count) 10-bit buffer(s) with no encode completion")
            }
            guard let buffer = state.free.popLast() else {
                state.skippedFrames &+= 1
                let skipped = state.skippedFrames
                if skipped <= 3 || skipped.isMultiple(of: 60) {
                    debugLog("HDRConverter: all \(poolDepth) 10-bit buffers in flight — skipping frame (\(skipped))")
                }
                return nil
            }
            let id = state.nextLeaseID
            state.nextLeaseID &+= 1
            state.leases[id] = Lease(buffer: buffer, startedNs: now)
            return (id, buffer)
        }) else { return nil }
        return (leaseID: leased.0, buffer: leased.1.value)
    }

    /// The lease an encoder must return when VideoToolbox is done with a
    /// pool buffer, or nil for any buffer this converter does not own. The ID
    /// is non-zero and stable, so VideoEncoder can carry it through
    /// `sourceFrameRefcon` without an allocation.
    static func leaseID(for buffer: CVPixelBuffer) -> UInt64? {
        let identity = ObjectIdentifier(buffer)
        return poolLock.withLock { state in
            state.leases.first { ObjectIdentifier($0.value.buffer.value) == identity }?.key
        }
    }

    /// Returns a leased buffer to the free list. Unknown IDs (already reclaimed,
    /// or belonging to a previous pool generation) are ignored, so a late
    /// completion cannot inject a foreign buffer into the pool.
    static func release(leaseID: UInt64) {
        poolLock.withLock { state in
            guard let lease = state.leases.removeValue(forKey: leaseID) else { return }
            state.free.append(lease.buffer)
        }
    }

    // MARK: - Conversion

    /// Convert an 8-bit 420f capture buffer into a leased 10-bit buffer.
    /// Returns nil when HDR is disabled, the pool is unavailable, or every
    /// buffer is still owned by VideoToolbox — the caller must then skip the
    /// frame rather than encode 8-bit data under a PQ VUI.
    static func convert(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled else { return nil }
        buildLUTsIfNeeded()

        guard VideoColorProfile.isSupportedEightBit420(CVPixelBufferGetPixelFormatType(src)) else {
            debugLog("HDRConverter: source is not 8-bit 4:2:0 (0x\(String(CVPixelBufferGetPixelFormatType(src), radix: 16))) — no conversion")
            return nil
        }

        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0, w % 2 == 0, h % 2 == 0,
              let lease = acquire(width: w, height: h) else { return nil }
        let dst = lease.buffer

        guard convertPlanes(src, dst, width: w, height: h) else {
            release(leaseID: lease.leaseID)
            return nil
        }
        // The lease is handed to the encoder by VideoEncoder.encode(pixelBuffer:).
        return dst
    }

    /// Geometry/plane-layout contract check plus the two LUT passes. Both the
    /// vImage LUT kernels validate neither the destination size nor the plane
    /// count, so a stale or odd buffer is an out-of-bounds write, not an error
    /// return.
    private static func convertPlanes(_ src: CVPixelBuffer, _ dst: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard let srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0),
              let srcC = CVPixelBufferGetBaseAddressOfPlane(src, 1),
              let dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
              let dstC = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else {
            debugLog("HDRConverter: unmapped plane (src planes=\(CVPixelBufferGetPlaneCount(src)), dst planes=\(CVPixelBufferGetPlaneCount(dst)))")
            return false
        }
        let cW = width / 2
        let cH = height / 2
        guard CVPixelBufferGetWidthOfPlane(src, 0) == width,
              CVPixelBufferGetHeightOfPlane(src, 0) == height,
              CVPixelBufferGetWidthOfPlane(dst, 0) == width,
              CVPixelBufferGetHeightOfPlane(dst, 0) == height,
              CVPixelBufferGetWidthOfPlane(src, 1) == cW,
              CVPixelBufferGetHeightOfPlane(src, 1) == cH,
              CVPixelBufferGetWidthOfPlane(dst, 1) == cW,
              CVPixelBufferGetHeightOfPlane(dst, 1) == cH else {
            debugLog("HDRConverter: plane geometry mismatch (src \(CVPixelBufferGetWidthOfPlane(src, 0))x\(CVPixelBufferGetHeightOfPlane(src, 0))/\(CVPixelBufferGetWidthOfPlane(src, 1))x\(CVPixelBufferGetHeightOfPlane(src, 1)), dst \(CVPixelBufferGetWidthOfPlane(dst, 0))x\(CVPixelBufferGetHeightOfPlane(dst, 0))/\(CVPixelBufferGetWidthOfPlane(dst, 1))x\(CVPixelBufferGetHeightOfPlane(dst, 1)), want \(width)x\(height))")
            return false
        }

        CVPixelBufferLockBaseAddress(src, [])
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, [])
        }

        var srcYBuf = vImage_Buffer(
            data: srcY, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, 0)
        )
        var dstYBuf = vImage_Buffer(
            data: dstY, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        )
        var srcCBuf = vImage_Buffer(
            data: srcC, height: vImagePixelCount(cH), width: vImagePixelCount(cW),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        )
        var dstCBuf = vImage_Buffer(
            data: dstC, height: vImagePixelCount(cH), width: vImagePixelCount(cW),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        )

        guard let tables = lutLock.withLock({ $0 }) else {
            debugLog("HDRConverter: LUTs unavailable")
            return false
        }
        let yResult = tables.luma.withUnsafeBufferPointer { yt -> vImage_Error in
            guard let base = yt.baseAddress else { return kvImageInvalidParameter }
            return vImageLookupTable_Planar8toPlanar16(&srcYBuf, &dstYBuf, base, vImage_Flags(kvImageNoFlags))
        }
        let cResult = tables.chroma.withUnsafeBufferPointer { ct -> vImage_Error in
            guard let base = ct.baseAddress else { return kvImageInvalidParameter }
            return vImageLookupTable_Planar8toPlanar16(&srcCBuf, &dstCBuf, base, vImage_Flags(kvImageNoFlags))
        }
        guard yResult == kvImageNoError, cResult == kvImageNoError else {
            debugLog("HDRConverter: vImage lookup failed (Y: \(yResult), C: \(cResult))")
            return false
        }
        return true
    }
}
