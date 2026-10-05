import Foundation
import VideoToolbox
import CoreMedia
import os

/// VUI colour signalling for the encode session.
///
/// ScreenCapture drives `SCStreamConfiguration.colorSpaceName` from
/// `SideScreen_exp_colorSpace`, so the captured pixels are matrix-converted for
/// the primaries named there. Android's CfL shader applies a hard-coded BT.709
/// matrix, so a wider-gamut stream that is NOT signalled is displayed with the
/// wrong matrix. BT.709 is the one case where saying nothing is correct:
/// VideoToolbox already infers it.
enum EncodedColorProfile {
    enum Primaries {
        case bt709
        case p3D65
        case bt2020
    }

    /// EXP-FORK knob (absent = BT.709, the production default).
    ///   SideScreen_exp_colorSpace "displayP3" | "bt2020" | "srgb"
    static var capturePrimaries: Primaries {
        switch UserDefaults.standard.string(forKey: "SideScreen_exp_colorSpace") {
        case "displayP3": return .p3D65
        case "bt2020": return .bt2020
        default: return .bt709
        }
    }

    /// The SCStreamConfiguration.colorSpaceName the active primaries imply.
    /// ScreenCapture should read this instead of repeating the key switch, so
    /// the key has exactly one owner.
    static var cgColorSpaceName: CFString? {
        switch capturePrimaries {
        case .bt709: return nil
        case .p3D65: return "kCGColorSpaceDisplayP3" as CFString
        case .bt2020: return "kCGColorSpaceITUR_2020" as CFString
        }
    }

    /// Writes the VUI. `hdr` means the frames really are 10-bit PQ/BT.2020, in
    /// which case it overrides the SDR primaries (the HDR path is by
    /// definition BT.2020). Returns true when anything was written.
    @discardableResult
    static func apply(to session: VTCompressionSession, hdr: Bool) -> Bool {
        let primaries: CFString
        let transfer: CFString
        let matrix: CFString
        if hdr {
            primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else {
            switch capturePrimaries {
            case .bt709:
                return false
            case .p3D65:
                // P3-D65 primaries carried on the 709 transfer/matrix: the
                // receiver still applies the 709 YCbCr matrix it already has.
                primaries = kCMFormatDescriptionColorPrimaries_P3_D65
                transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
                matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            case .bt2020:
                primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020
                transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
                matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            }
        }
        let primaryStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: primaries)
        let transferStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: transfer)
        let matrixStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: matrix)
        debugLog("VUI: primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) (status \(primaryStatus)/\(transferStatus)/\(matrixStatus))")
        return true
    }
}

class VideoEncoder {
    /// kVTCompressionPropertyKey_AverageBitRate is a CFNumber<SInt32>, so a
    /// target above Int32.max fails the property set silently and 0 or negative
    /// makes VideoToolbox drop the rate control. Everything that reaches the
    /// session goes through this clamp, including the experimental override,
    /// which is user-typed text.
    static let bitrateFloorMbps = 1
    static let bitrateCeilingMbps = 2_000

    private struct SessionConfig {
        var bitrateMbps: Int
        var quality: String
        var gamingBoost: Bool
        var frameRate: Int
    }

    private struct EncoderState {
        var pendingForceKeyframe = false
        var encodeCalls: UInt64 = 0
        var encodeErrors: UInt64 = 0
        var encodedOutputs: UInt64 = 0
        var pressureSkips: UInt64 = 0
        var colorimetryMismatches: UInt64 = 0
        var config: SessionConfig
        /// The VT output callback is documented to run on another thread, so the
        /// sink is read under the same lock that publishes it.
        var onEncodedFrame: ((Data, UInt64, Bool) -> Void)?
    }

    /// The session handle is swapped by the settings thread while the encode
    /// queue is calling into it, so every read, write and teardown of the handle
    /// happens under this lock. `hdrSignalled` is the VUI state of the session
    /// that is currently published, used to detect frames that do not match it.
    private struct SessionHandle: @unchecked Sendable {
        let session: VTCompressionSession
        let hdrSignalled: Bool
    }

    private let width: Int
    private let height: Int
    let codec: StreamCodec
    private let maxBitrateMbps: Int?
    private let wireless: Bool

    private let stateLock = OSAllocatedUnfairLock(
        initialState: EncoderState(config: SessionConfig(bitrateMbps: 20, quality: "medium", gamingBoost: false, frameRate: 60))
    )
    private let sessionLock = OSAllocatedUnfairLock<SessionHandle?>(initialState: nil)

    /// data, timestamp, isKeyframe
    var onEncodedFrame: ((Data, UInt64, Bool) -> Void)? {
        get { stateLock.withLock { $0.onEncodedFrame } }
        set { stateLock.withLock { $0.onEncodedFrame = newValue } }
    }

    init(width: Int, height: Int, codec: StreamCodec = .hevc, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60, maxBitrateMbps: Int? = nil, wireless: Bool = false) {
        self.width = width
        self.height = height
        self.codec = codec
        // gamingBoost = the "ultralow" bitrate preset (6/9 Mbps bounded): the
        // bounded-frame-size profile that keeps encode time flat under motion
        // (the old gamingBoost overrides were no-ops once Quality took over
        // rate control — audit Entry S).
        stateLock.withLock { state in
            state.config = SessionConfig(
                bitrateMbps: bitrateMbps,
                quality: gamingBoost ? "ultralow" : quality,
                gamingBoost: gamingBoost,
                frameRate: frameRate
            )
        }
        self.maxBitrateMbps = maxBitrateMbps.map { max(Self.bitrateFloorMbps, $0) }
        self.wireless = wireless
        sessionLock.withLock { $0 = makeConfiguredSession() }
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        stateLock.withLock { state in
            state.config = SessionConfig(
                bitrateMbps: bitrateMbps,
                quality: gamingBoost ? "ultralow" : quality,
                gamingBoost: gamingBoost,
                frameRate: state.config.frameRate
            )
        }
        // A failed allocation must not take the working session down with it.
        // Publishing nil would make every later encode() take the `.noSession`
        // path and drop frames silently — one transient VideoToolbox allocation
        // failure would leave the tablet black until the app restarted, with no
        // retry path back to a live session.
        guard let created = makeConfiguredSession() else {
            debugLog("VideoToolbox session rebuild failed — keeping the current session")
            return
        }
        // Swap first, drain second: any encode that is already inside
        // VTCompressionSessionEncodeFrame has finished by the time this returns,
        // so the outgoing session can be completed and invalidated without
        // another thread being inside it.
        let outgoing = sessionLock.withLock { current -> SessionHandle? in
            let outgoing = current
            current = created
            return outgoing
        }
        if let previous = outgoing?.session {
            VTCompressionSessionCompleteFrames(previous, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(previous)
        }
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting up to one full GOP for the next scheduled keyframe.
    func requestKeyframe() {
        stateLock.withLock { $0.pendingForceKeyframe = true }
    }

    /// Result of one submission attempt. `noSession` means the settings thread
    /// swapped the session out and the frame never reached VideoToolbox, so no
    /// output callback will run.
    private enum EncodeOutcome {
        case submitted(OSStatus)
        case noSession
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        // A pooled HDR buffer must not go back into the pool until VideoToolbox
        // is done reading it. The lease rides along as sourceFrameRefcon and is
        // released by the output callback; a skipped or failed encode has no
        // callback, so it releases here.
        let leaseID = HDRConverter.enabled ? HDRConverter.leaseID(for: pixelBuffer) : nil

        let callNumber: UInt64? = wireless
            ? stateLock.withLock { state -> UInt64 in
                state.encodeCalls &+= 1
                return state.encodeCalls
            }
            : nil

        // Consume the force request first: recovery/startup keyframes must cut
        // through congestion. Routine captures, however, can be skipped safely
        // BEFORE VideoToolbox sees them when the wireless sender is backed up.
        let shouldForceKeyframe = stateLock.withLock { state -> Bool in
            guard state.pendingForceKeyframe else { return false }
            state.pendingForceKeyframe = false
            return true
        }
        if wireless && !shouldForceKeyframe && WirelessTransportPressure.shouldPauseEncoding {
            stateLock.withLock { $0.pressureSkips &+= 1 }
            if let leaseID { HDRConverter.release(leaseID: leaseID) }
            return
        }

        let config = stateLock.withLock { $0.config }
        let duration = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let frameIsTenBit = Self.isTenBitBuffer(pixelBuffer)

        // The lock spans the submission so a concurrent swap cannot invalidate
        // the session between this read and the call. The image is wrapped so
        // the closure stays Sendable: the lock, not the wrapper, is what orders
        // the submit against a concurrent teardown.
        let image = SendableImageBuffer(pixelBuffer)
        let outcome = sessionLock.withLock { handle -> EncodeOutcome in
            guard let session = handle?.session else { return .noSession }
            // Measures the *submit* call, not the encode itself: the hardware
            // media engine does the work asynchronously and reports through the
            // output callback below. The gap between this interval and
            // vtOutputCallback is the encoder's actual latency.
            let encodeSignpost = FramePipelineSignpost.vtEncodeSubmit.beginInterval("submit")
            defer { FramePipelineSignpost.vtEncodeSubmit.endInterval("submit", encodeSignpost) }
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: image.value,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                frameProperties: frameProperties,
                sourceFrameRefcon: hdrLeaseRefcon(leaseID),
                infoFlagsOut: nil
            )
            return .submitted(status)
        }

        switch outcome {
        case .noSession:
            if let leaseID { HDRConverter.release(leaseID: leaseID) }
        case let .submitted(status) where status != noErr:
            // The forced IDR that was supposed to ride this frame is still owed:
            // a non-monotonic PTS, a session invalidated mid-flight or
            // kVTVideoEncoderMalfunctionErr all drop the request, and the client
            // then shows frozen/black video until the next natural GOP (up to 5 s
            // on wireless). This is exactly the codec-switch/reconnect path.
            if shouldForceKeyframe {
                stateLock.withLock { state in state.pendingForceKeyframe = true }
            }
            let errorCount = stateLock.withLock { state -> UInt64 in
                state.encodeErrors &+= 1
                return state.encodeErrors
            }
            if let leaseID { HDRConverter.release(leaseID: leaseID) }
            // Logged for USB too: a silently dropped encode is indistinguishable
            // from a stalled display on either transport.
            if errorCount <= 3 || errorCount.isMultiple(of: 60) {
                debugLog("VideoToolbox encode rejected frame (\(wireless ? "wireless" : "usb")): status=\(status), errors=\(errorCount)")
            }
        case .submitted:
            break
        }

        if sessionLock.withLock({ $0?.hdrSignalled ?? false }) != frameIsTenBit {
            noteColorimetryMismatch(frameIsTenBit: frameIsTenBit)
        }

        if wireless, let callNumber = callNumber, callNumber.isMultiple(of: 60) {
            let stats = stateLock.withLock { state in
                (state.encodeCalls, state.encodedOutputs, state.encodeErrors, state.pressureSkips, state.colorimetryMismatches)
            }
            let pressure = WirelessTransportPressure.diagnosticSnapshot()
            debugLog(
                "Encoder cadence: calls=\(stats.0), outputs=\(stats.1), " +
                "errors=\(stats.2), pressureSkips=\(stats.3), " +
                "colorimetryMismatches=\(stats.4), " +
                "pressureInFlight=\(pressure.sendsInFlight), " +
                "pressureBytes=\(pressure.bytesInFlight), " +
                "tcpAvailable=\(pressure.availableSendBuffer.map(String.init) ?? "unknown")"
            )
        }
    }

    func noteEncodedOutput() {
        guard wireless else { return }
        stateLock.withLock { $0.encodedOutputs &+= 1 }
    }

    private static func isTenBitBuffer(_ buffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// A frame whose bit depth does not match the session's VUI means the
    /// receiver is applying a transfer function the pixels were not encoded
    /// with (PQ on 8-bit SDR, or the reverse). It cannot be fixed per frame —
    /// the VUI lives in the bitstream header — so it is surfaced loudly.
    private func noteColorimetryMismatch(frameIsTenBit: Bool) {
        let count = stateLock.withLock { state -> UInt64 in
            state.colorimetryMismatches &+= 1
            return state.colorimetryMismatches
        }
        if count <= 3 || count.isMultiple(of: 60) {
            let signalled = sessionLock.withLock { $0?.hdrSignalled ?? false }
            debugLog("Colorimetry mismatch #\(count): session VUI says \(signalled ? "10-bit PQ" : "8-bit SDR") but the frame is \(frameIsTenBit ? "10-bit" : "8-bit") — ScreenCapture fell back after HDRConverter.convert returned nil; the stream is mislabelled until the session is rebuilt")
        }
    }

    deinit {
        // No CompleteFrames here: it emits every pending frame's output
        // callback synchronously, which resurrects a half-taken-down object
        // through the unretained refcon and fires after capture has stopped
        // accepting frames. Invalidate drops the pending frames instead.
        let outgoing = sessionLock.withLock { current -> SessionHandle? in
            let outgoing = current
            current = nil
            return outgoing
        }
        if let session = outgoing?.session {
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Session configuration

    /// Test seam: the next `makeConfiguredSession()` fails when set, so the
    /// "a rebuild could not be built" path is testable on machines where a
    /// real allocation failure cannot be provoked. False in normal use.
    /// Consume-once: each call that observes it clears it, so a test can fail
    /// exactly one rebuild and watch the next one succeed.
    static var failNextSessionCreation = false

    /// Test-only observability: whether a compression session is currently
    /// published. A read-only view of existing state — nothing in the app
    /// depends on it.
    var hasLiveSession: Bool { sessionLock.withLock { $0 != nil } }

    /// Builds a fully configured session without publishing it, so a rebuild can
    /// swap atomically and tear the old session down afterwards.
    private func makeConfiguredSession() -> SessionHandle? {
        if Self.failNextSessionCreation {
            Self.failNextSessionCreation = false
            debugLog("Injected VideoToolbox session creation failure (test seam)")
            return nil
        }
        let config = stateLock.withLock { $0.config }
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            debugLog("Failed to create compression session: \(status)")
            return nil
        }

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let hdrRequested = HDRConverter.isTenBitPQActive(width: width, height: height)
        // VideoToolbox exposes no 10-bit H.264 profile constant, so an AVC
        // session cannot carry the PQ VUI: declaring it would label 8-bit
        // frames as HDR. H.264 therefore stays 8-bit SDR.
        let hdrSignalled = hdrRequested && codec == .hevc
        if hdrRequested && codec != .hevc {
            debugLog("HDR mode with H.264: 10-bit PQ cannot be signalled over AVC (no Main10 profile constant) — encoding BT.709")
        }

        // EXP-FORK knobs (SideScreen_exp_*; absent = current production behavior):
        //   SideScreen_exp_profile  "main10" -> HEVC Main10 (10-bit) profile
        //   SideScreen_exp_bitrate  Int Mbps  -> override the preset bitrate target
        //   SideScreen_exp_gop      Int frames -> keyframe interval override
        //   SideScreen_exp_bframes  Bool       -> allow B-frames (default false)
        let expProfile = UserDefaults.standard.string(forKey: "SideScreen_exp_profile")
        let profile: CFString
        if codec == .hevc {
            // HDR mode forces Main10 (10-bit HEVC) — the tablet needs it for the
            // HDR path regardless of the profile knob.
            profile = (hdrSignalled || expProfile == "main10") ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : (expProfile == "main42210" ? kVTProfileLevel_HEVC_Main42210_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            // Constrained Baseline (symbol 0x42), not Main (0x4D): the Android 8/9
            // Baseline-only AVC decoders still in the field reject Main outright,
            // and screen content gains nothing from it. The cost is CAVLC
            // entropy coding instead of CABAC — roughly 10-15% more bytes for
            // the same quality at a bitrate target that is deliberately bounded
            // anyway.
            profile = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        // CUT (audit Entry S, 2026-08-16 follow-up): Quality-based rate control
        // is unbounded on this path — with kVTCompressionPropertyKey_Quality
        // set, VideoToolbox ignores AverageBitRate AND DataRateLimits
        // (receipts: byte-identical output at 10 vs 60 Mbps; 73.6 Mbps
        // measured against 30/45 limits). Motion bursts then overloaded the
        // transport/tablet decoder (the 34-39fps collapse + drop cascades).
        // Production now uses bitrate-based VBR: AverageBitRate as the soft
        // target, DataRateLimits as the 1-second hard cap at 1.5x.
        let presetMbps: Int
        switch config.quality {
        case "ultralow": presetMbps = 6
        case "low": presetMbps = 12
        case "medium": presetMbps = 20
        case "high": presetMbps = 30
        // EXP-FORK ultra ladder, now bitrate-bounded
        case "extrahigh": presetMbps = 40
        case "max": presetMbps = 50
        case "ultra": presetMbps = 60
        default: presetMbps = 20
        }

        let expBitrate = Self.clampBitrateMbps(
            UserDefaults.standard.object(forKey: "SideScreen_exp_bitrate") as? Int
        )
        // Transport mode is captured when this encoder is created. Reading the
        // mutable preference here lets a mode toggle or stale defaults change
        // rate control/GOP policy underneath an already-running USB session.
        let isWireless = wireless

        // The historic UI bitrate control was designed for the USB path and
        // defaults to 1000 Mbps. Feeding that value into Wi-Fi defeats the
        // bounded 6..60 Mbps quality ladder and can ask VideoToolbox for a
        // gigabit stream before TCP/backpressure has any chance to help.
        // Wireless follows the quality preset, then applies its session cap.
        // USB keeps the old explicit floor for users who deliberately want
        // very high cable bitrate. The wireless session cap also bounds an
        // experimental bitrate override so a debug knob cannot defeat the
        // production LAN safety contract.
        let uiFloor = (!isWireless && config.bitrateMbps >= 100 && config.bitrateMbps <= 2000) ? config.bitrateMbps : 0
        let uncappedTargetMbps = expBitrate
            ?? ((config.gamingBoost || isWireless) ? presetMbps : max(presetMbps, uiFloor))
        let sessionBitrateCapMbps = (isWireless
            ? WirelessFreshnessPolicy.averageBitrateMbps
            : maxBitrateMbps
        ).map { min(max($0, Self.bitrateFloorMbps), Self.bitrateCeilingMbps) }
        let cappedTargetMbps = sessionBitrateCapMbps.map { min(uncappedTargetMbps, $0) } ?? uncappedTargetMbps
        let targetMbps = Self.clampBitrateMbps(cappedTargetMbps) ?? Self.bitrateFloorMbps
        let avgBps = targetMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBps as CFNumber)

        // Hard cap: bytes over a 1s window at 1.5x target — the guarantee
        // that keeps per-frame size (and thus decoder+transport load) bounded
        // during complex motion. This is the property pair VideoToolbox
        // documents for live streaming, and it is effective here: encode()
        // submits a real per-frame duration, which is what makes the rate
        // controller (and therefore DataRateLimits) meaningful. (Passing
        // kCMTimeInvalid for duration, as the VirtualDisplayKit reference does,
        // gives the encoder no timeline and no rate control at all.)
        // The property pair only works because Quality is never set on this
        // session.
        let requestedPeakMbps = targetMbps + targetMbps / 2
        let peakCeilingMbps = isWireless
            ? WirelessFreshnessPolicy.peakBitrateMbps
            : sessionBitrateCapMbps.map { $0 + $0 / 2 } ?? Int.max
        let peakMbps = min(requestedPeakMbps, peakCeilingMbps)
        let capBytes = peakMbps * 1_000_000 / 8
        let dataRateLimits = [capBytes, 1] as CFArray
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        debugLog("Rate control: path=\(isWireless ? "wireless" : "usb") avg=\(targetMbps)Mbps cap=\(peakMbps)Mbps/1s (DataRateLimits status=\(limitStatus))")

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: config.frameRate as CFNumber)

        // TCP preserves reference frames, reconnect/startup forces an IDR, and
        // Android explicitly requests one when its decoder is reset or loses
        // input. Wireless therefore uses a longer periodic safety GOP to avoid
        // paying a large full-frame refresh every second during continuous
        // motion. USB keeps the existing one-second cadence. The Android
        // stale-keyframe watchdog sits just beyond the five-second wireless GOP.
        // SideScreen_exp_gop remains an explicit frame-count override.
        let expGop = UserDefaults.standard.object(forKey: "SideScreen_exp_gop") as? Int
        let defaultGopFrames = config.frameRate * (isWireless ? 5 : 1)
        let gopFrames = max(1, expGop ?? defaultGopFrames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(gopFrames) / Double(config.frameRate) as CFNumber)

        // Critical for low latency - NO frame reordering (no B-frames)
        let expBFrames = UserDefaults.standard.object(forKey: "SideScreen_exp_bframes") as? Bool ?? false
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: (expBFrames ? kCFBooleanTrue : kCFBooleanFalse))

        // ALWAYS zero frame delay for real-time streaming (not just gaming boost)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Rate control note: kVTCompressionPropertyKey_Quality is deliberately
        // NEVER set here — it overrides bitrate-based control entirely (see
        // the rate-control block above for the receipts). Preset names map to
        // bitrate targets; gamingBoost pins quality="ultralow" in the
        // constructor, i.e. a fast 6/9 Mbps bounded profile.

        // EXP-FORK: HDR signalling (SideScreen_exp_hdr=1) — write the VUI
        // colorimetry via SESSION properties (pixel-buffer attachments are
        // ignored by VT — verified 2026-08-15). Only written when a 10-bit PQ
        // buffer is genuinely what gets encoded; the SDR path signals only when
        // the captured primaries are not BT.709. Content must match:
        // 10-bit buffers, PQ-encoded, BT.2020. NOTE: HLG transfer breaks the HW
        // encoder (-12902 at encode); PQ is the working combination.
        if hdrSignalled {
            EncodedColorProfile.apply(to: session, hdr: true)
        } else {
            EncodedColorProfile.apply(to: session, hdr: false)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        let mode = config.gamingBoost ? "🎮 GAMING BOOST" : config.quality.uppercased()
        let codecName = codec == .hevc ? "H.265" : "H.264"
        debugLog("VideoToolbox encoder configured (" + codecName + ", quality=" + mode + ", " + String(config.frameRate) + "fps)")
        return SessionHandle(session: session, hdrSignalled: hdrSignalled)
    }

    private static func clampBitrateMbps(_ value: Int?) -> Int? {
        value.map { min(max($0, bitrateFloorMbps), bitrateCeilingMbps) }
    }
}

// Static start code to avoid repeated allocations
private let nalStartCode: [UInt8] = [0, 0, 0, 1]
private let plausibleFrameAgeNs: UInt64 = 60_000_000_000
/// A parameter-set count larger than this is a corrupt format description, not
/// a real VPS/SPS/PPS set.
private let maxParameterSetCount = 16

/// CVPixelBuffer is a CF type the compiler refuses to treat as Sendable. This
/// wrapper only exists so the submit can run inside the session lock.
private struct SendableImageBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// The HDR lease rides through `sourceFrameRefcon` as a plain integer so the
/// per-frame path stays allocation-free. Lease IDs start at 1, so a null refcon
/// always means "no lease" and the round trip is exact.
private func hdrLeaseRefcon(_ leaseID: UInt64?) -> UnsafeMutableRawPointer? {
    guard let leaseID, leaseID != 0 else { return nil }
    return UnsafeMutableRawPointer(bitPattern: Int(bitPattern: UInt(truncatingIfNeeded: leaseID)))
}

private func hdrLeaseID(from refcon: UnsafeMutableRawPointer) -> UInt64 {
    UInt64(UInt(bitPattern: UnsafeRawPointer(refcon)))
}

/// VideoToolbox preserves the submitted presentation timestamp on the encoded
/// sample. Most SideScreen capture paths use the host-time clock; when they do,
/// reuse that PTS for frame-age profiling instead of heap-allocating an 8-byte
/// sourceFrameRefcon on every frame. If a source uses another timebase,
/// fail closed to current uptime so transport metadata remains well formed.
///
/// The plausible-PTS path and the fail-closed path are different clocks'
/// opinions about the same frame, so the raw result can step backwards from one
/// frame to the next. The receiver clocks this stream against a single
/// monotonic reference, so a backwards step would make every derived
/// capture-to-arrival age wrong. Clamp to the last value emitted.
private let lastEmittedFrameTimestamp = OSAllocatedUnfairLock(initialState: UInt64(0))

private func frameTimestampNanoseconds(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isNumeric else { return monotonicFrameTimestamp(now) }

    let seconds = pts.seconds
    guard seconds.isFinite, seconds >= 0 else { return monotonicFrameTimestamp(now) }
    let ptsNsDouble = seconds * 1_000_000_000.0
    guard ptsNsDouble <= Double(now) else { return monotonicFrameTimestamp(now) }

    let ptsNs = UInt64(ptsNsDouble.rounded())
    guard now - ptsNs <= plausibleFrameAgeNs else { return monotonicFrameTimestamp(now) }
    return monotonicFrameTimestamp(ptsNs)
}

private func monotonicFrameTimestamp(_ candidate: UInt64) -> UInt64 {
    lastEmittedFrameTimestamp.withLock { last in
        let value = max(candidate, last)
        last = value
        return value
    }
}

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefcon, status, _, sampleBuffer) in
    guard let refcon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    // The HDR lease rides here: VideoToolbox is done with the pixel buffer, so
    // the converter can hand it to the next frame. Released on every exit path
    // because a leaked lease would cost the pool a buffer until it is reclaimed.
    if let sourceFrameRefcon {
        HDRConverter.release(leaseID: hdrLeaseID(from: sourceFrameRefcon))
    }

    guard status == noErr,
          let sampleBuffer = sampleBuffer else {
        return
    }

    // The one stage in the whole pipeline with real managed byte work: this
    // copies the already-compressed bitstream into the buffer that goes on the
    // wire. Everything else on the host either hands off to a platform API or
    // is already SIMD, so this is where any Swift-vs-C/Rust difference would
    // actually show up if it exists at all.
    let annexSignpost = FramePipelineSignpost.vtOutputCallback.beginInterval("annexb")
    defer { FramePipelineSignpost.vtOutputCallback.endInterval("annexb", annexSignpost) }

    let timestamp = frameTimestampNanoseconds(sampleBuffer)

    // Extract encoded data
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let statusCode = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )

    guard statusCode == kCMBlockBufferNoErr,
          let dataPointer = dataPointer else {
        return
    }

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = VideoEncoder.isSyncSample(attachments: attachments)

    // Pre-allocate estimated size to reduce reallocations
    let estimatedSize = totalLength + (isKeyframe ? 256 : 0) + 32
    var frameData = Data(capacity: estimatedSize)

    if isKeyframe {
        appendParameterSets(for: sampleBuffer, codec: encoder.codec, into: &frameData)
    }

    VideoEncoder.appendAnnexBFrame(
        from: UnsafeRawPointer(dataPointer),
        totalLength: totalLength,
        into: &frameData
    )

    encoder.noteEncodedOutput()
    encoder.onEncodedFrame?(frameData, timestamp, isKeyframe)
}

extension VideoEncoder {
    /// CoreMedia's contract (CMSampleBuffer.h): "absence of this key implies
    /// Sync". VideoToolbox relies on it — its IDRs carry no NotSync key at all
    /// (`[DependsOnOthers: 0]`), and only dependent frames carry NotSync=true.
    /// Demanding an explicit NotSync=false therefore classified every real
    /// keyframe as a P-frame, and StreamingServer's wait-for-sync gate dropped
    /// the entire stream. Only a present key with a non-Boolean value is
    /// treated as "not sync", since that is malformed rather than absent.
    static func isSyncSample(attachments: [[CFString: Any]]?) -> Bool {
        guard let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] else { return true }
        return (notSync as? Bool) == false
    }

    /// Converts length-prefixed NAL units to Annex-B (4-byte start codes) and
    /// appends them. Both loop invariants are load-bearing: without them a
    /// corrupt length word is an out-of-bounds read of up to 4 GiB appended
    /// straight into the bytes that go on the wire. A violation truncates the
    /// frame instead of crashing — a damaged frame is recoverable, a dead
    /// sender is not.
    static func appendAnnexBFrame(from pointer: UnsafeRawPointer, totalLength: Int, into frameData: inout Data) {
        var offset = 0
        while offset < totalLength {
            guard totalLength - offset >= 4 else {
                debugLog("Annex-B walk: \(totalLength - offset) trailing byte(s) with no length prefix — truncating frame")
                break
            }
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = UInt32(bigEndian: nalLength)
            offset += 4
            guard Int(nalLength) <= totalLength - offset else {
                debugLog("Annex-B walk: NAL length \(nalLength) exceeds \(totalLength - offset) remaining byte(s) — truncating frame")
                break
            }
            frameData.append(contentsOf: nalStartCode)
            frameData.append(pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
            offset += Int(nalLength)
        }
    }
}

/// Prepends VPS/SPS/PPS for HEVC, SPS/PPS for H.264. Every fetch is status
/// checked: an unchecked pointer/size pair from a bad format description is an
/// arbitrary read.
private func appendParameterSets(for sampleBuffer: CMSampleBuffer, codec: StreamCodec, into frameData: inout Data) {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

    var parameterSetCount: Int = 0
    let countStatus: OSStatus
    if codec == .hevc {
        countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
    } else {
        countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
    }
    guard countStatus == noErr else {
        debugLog("Parameter set count query failed: \(countStatus) — keyframe sent without SPS/PPS")
        return
    }
    guard parameterSetCount > 0, parameterSetCount <= maxParameterSetCount else {
        debugLog("Implausible parameter set count \(parameterSetCount) — keyframe sent without SPS/PPS")
        return
    }

    for i in 0..<parameterSetCount {
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0
        let status: OSStatus
        if codec == .hevc {
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        } else {
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        }
        guard status == noErr, let pointer = parameterSetPointer, parameterSetSize > 0 else {
            debugLog("Parameter set \(i) fetch failed (status \(status)) — stopping at \(i) of \(parameterSetCount)")
            break
        }
        frameData.append(contentsOf: nalStartCode)
        frameData.append(pointer, count: parameterSetSize)
    }
}
