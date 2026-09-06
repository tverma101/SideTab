import Foundation
import VideoToolbox
import CoreMedia
import os

class VideoEncoder {
    private struct EncoderState {
        var pendingForceKeyframe = false
        var pendingForcePressureGeneration: UInt64?
    }

    private var compressionSession: VTCompressionSession?
    var onEncodedFrame: ((Data, UInt64, Bool) -> Void)?  // data, timestamp, isKeyframe
    private var width: Int
    private var height: Int
    let codec: StreamCodec
    private var bitrateMbps: Int = 20
    private var quality: String = "medium"
    private var gamingBoost: Bool = false
    private var frameRate: Int = 60
    private let stateLock = OSAllocatedUnfairLock(initialState: EncoderState())
    init(width: Int, height: Int, codec: StreamCodec = .hevc, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60) {
        self.width = width
        self.height = height
        self.codec = codec
        // gamingBoost = the "ultralow" bitrate preset (6/9 Mbps bounded): the
        // bounded-frame-size profile that keeps encode time flat under motion
        // (the old gamingBoost overrides were no-ops once Quality took over
        // rate control — audit Entry S).
        self.bitrateMbps = bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost
        self.frameRate = frameRate
        setupCompressionSession()
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        self.bitrateMbps = bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost

        // Drain pending frames before invalidation
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        setupCompressionSession()
    }

    private func setupCompressionSession() {
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

        guard status == noErr, let session = session else {
            debugLog("Failed to create compression session: \(status)")
            return
        }

        compressionSession = session

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // H.264 Main profile: decodable by every AVC hardware decoder
        // (Baseline/Main/High all accept Main-constrained streams' feature
        // set we use). High adds 8x8 transform that some low-end vendor OMX
        // decoders reject — not worth the marginal gain for screen content.
        // EXP-FORK knobs (SideScreen_exp_*; absent = current production behavior):
        //   SideScreen_exp_profile  "main10" -> HEVC Main10 (10-bit) profile
        //   SideScreen_exp_bitrate  Int Mbps  -> override the preset bitrate target
        //   SideScreen_exp_gop      Int frames -> keyframe interval override
        //   SideScreen_exp_bframes  Bool       -> allow B-frames (default false)
        let expProfile = UserDefaults.standard.string(forKey: "SideScreen_exp_profile")
        // EXP-FORK: HDR mode forces Main10 (10-bit HEVC) — the tablet needs it
        // for the HDR path regardless of the profile knob.
        let hdrMode = UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr")
        let profile: CFString = codec == .hevc
            ? (hdrMode || expProfile == "main10" ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : (expProfile == "main42210" ? kVTProfileLevel_HEVC_Main42210_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel))
            : kVTProfileLevel_H264_Main_AutoLevel
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
        switch quality {
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

        let expBitrate = UserDefaults.standard.object(forKey: "SideScreen_exp_bitrate") as? Int
        let connectionMode = UserDefaults.standard.string(forKey: "SideScreen_connectionMode") ?? "usb"
        let isWireless = connectionMode == "wireless"

        // The historic UI bitrate control was designed for the USB path and
        // defaults to 1000 Mbps. Feeding that value into Wi-Fi defeats the
        // bounded 6..60 Mbps quality ladder and can ask VideoToolbox for a
        // gigabit stream before TCP/backpressure has any chance to help.
        // Wireless therefore follows the quality preset exactly. USB keeps the
        // old explicit floor for users who deliberately want very high cable
        // bitrate. SideScreen_exp_bitrate remains an intentional override for
        // experiments on either transport.
        let uiFloor = (!isWireless && bitrateMbps >= 100 && bitrateMbps <= 2000) ? bitrateMbps : 0
        let targetMbps = expBitrate ?? ((gamingBoost || isWireless) ? presetMbps : max(presetMbps, uiFloor))
        let avgBps = targetMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBps as CFNumber)

        // Hard cap: bytes over a 1s window at 1.5x target — the guarantee
        // that keeps per-frame size (and thus decoder+transport load) bounded
        // during complex motion. This is the property pair VideoToolbox
        // documents for live streaming; it only works because Quality is
        // never set on this session.
        let capBytes = Int(Double(targetMbps) * 1.5 * 1_000_000.0 / 8.0)
        let dataRateLimits = [capBytes, 1] as CFArray
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        debugLog("Rate control: path=\(isWireless ? "wireless" : "usb") avg=\(targetMbps)Mbps cap=\(Int(Double(targetMbps) * 1.5))Mbps/1s (DataRateLimits status=\(limitStatus))")

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        // TCP preserves reference frames, reconnect/startup forces an IDR, and
        // Android explicitly requests one when its decoder is reset or loses
        // input. Wireless therefore uses a longer periodic safety GOP to avoid
        // paying a large full-frame refresh every second during continuous
        // motion. USB keeps the existing one-second cadence. The Android
        // stale-keyframe watchdog sits just beyond the five-second wireless GOP.
        // SideScreen_exp_gop remains an explicit frame-count override.
        let expGop = UserDefaults.standard.object(forKey: "SideScreen_exp_gop") as? Int
        let defaultGopFrames = frameRate * (isWireless ? 5 : 1)
        let gopFrames = expGop ?? defaultGopFrames
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(gopFrames) / Double(frameRate) as CFNumber)

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

        // EXP-FORK: HDR signaling (SideScreen_exp_hdr=1) — write HEVC VUI
        // colorimetry via SESSION properties (pixel-buffer attachments are
        // ignored by VT — verified 2026-08-15). Content must match: 10-bit
        // buffers, PQ-encoded, BT.2020. NOTE: HLG transfer breaks the HW
        // encoder (-12902 at encode); PQ is the working combination.
        if UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr") {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCMFormatDescriptionColorPrimaries_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
            debugLog("HDR mode: BT.2020 primaries, PQ transfer, BT.2020 matrix (VUI)")
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        let mode = gamingBoost ? "🎮 GAMING BOOST" : quality.uppercased()
        let codecName = codec == .hevc ? "H.265" : "H.264"
        debugLog("VideoToolbox encoder configured (" + codecName + ", quality=" + mode + ", " + String(frameRate) + "fps)")
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting up to one full GOP for the next scheduled keyframe.
    func requestKeyframe() {
        let pressureGeneration = WirelessTransportPressure.noteForcedCapturePending()
        stateLock.withLock { state in
            state.pendingForceKeyframe = true
            state.pendingForcePressureGeneration = pressureGeneration
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }

        // Consume the force request first: recovery/startup keyframes must cut
        // through congestion. Routine captures, however, can be skipped safely
        // BEFORE VideoToolbox sees them when the wireless sender is backed up.
        let forceState = stateLock.withLock { state -> (force: Bool, pressureGeneration: UInt64?) in
            guard state.pendingForceKeyframe else { return (false, nil) }
            state.pendingForceKeyframe = false
            let pressureGeneration = state.pendingForcePressureGeneration
            state.pendingForcePressureGeneration = nil
            return (true, pressureGeneration)
        }
        if let pressureGeneration = forceState.pressureGeneration {
            WirelessTransportPressure.clearForcedCapturePending(generation: pressureGeneration)
        }
        if !forceState.force && WirelessTransportPressure.shouldPauseEncoding {
            return
        }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let frameProperties: CFDictionary? = forceState.force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

// Static start code used only for keyframe parameter sets.
private let nalStartCode: [UInt8] = [0, 0, 0, 1]
private let plausibleFrameAgeNs: UInt64 = 60_000_000_000

/// VideoToolbox preserves the submitted presentation timestamp on the encoded
/// sample. Most SideScreen capture paths use the host-time clock; when they do,
/// reuse that PTS for frame-age profiling instead of heap-allocating an 8-byte
/// sourceFrameRefcon on every frame. If a source ever uses another timebase,
/// fail closed to current uptime so transport metadata remains well formed.
private func frameTimestampNanoseconds(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isNumeric else { return now }

    let seconds = pts.seconds
    guard seconds.isFinite, seconds >= 0 else { return now }
    let ptsNsDouble = seconds * 1_000_000_000.0
    guard ptsNsDouble <= Double(now) else { return now }

    let ptsNs = UInt64(ptsNsDouble.rounded())
    guard now - ptsNs <= plausibleFrameAgeNs else { return now }
    return ptsNs
}

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, _, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
    let timestamp = frameTimestampNanoseconds(sampleBuffer)

    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let totalLength = CMBlockBufferGetDataLength(dataBuffer)
    guard totalLength > 0 else { return }

    // Check if this is a keyframe.
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // Keyframes prepend their parameter sets. The encoded CMBlockBuffer payload
    // itself is then copied exactly once into uninitialized final storage;
    // unlike the old NAL loop, payload bytes are never zero-filled or appended
    // and copy-walked per NAL.
    var parameterPrefix = Data(capacity: isKeyframe ? 256 : 0)

    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Prepend parameter sets: VPS/SPS/PPS for HEVC, SPS/PPS for H.264.
            var parameterSetCount: Int = 0
            let countStatus: OSStatus
            if encoder.codec == .hevc {
                countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            } else {
                countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            }
            if countStatus != noErr {
                debugLog("Parameter set count query failed: \(countStatus) — keyframe sent without SPS/PPS")
                parameterSetCount = 0
            }

            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize: Int = 0
                if encoder.codec == .hevc {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }

                if let pointer = parameterSetPointer {
                    parameterPrefix.append(contentsOf: nalStartCode)
                    parameterPrefix.append(pointer, count: parameterSetSize)
                }
            }
        }
    }

    let payloadOffset = parameterPrefix.count
    let finalSize = payloadOffset + totalLength
    guard let storage = malloc(finalSize) else {
        debugLog("Encoded frame allocation failed: \(finalSize) bytes")
        return
    }

    if payloadOffset > 0 {
        parameterPrefix.withUnsafeBytes { prefixBytes in
            if let source = prefixBytes.baseAddress {
                storage.copyMemory(from: source, byteCount: payloadOffset)
            }
        }
    }

    let copyStatus = CMBlockBufferCopyDataBytes(
        dataBuffer,
        atOffset: 0,
        dataLength: totalLength,
        destination: storage.advanced(by: payloadOffset)
    )
    guard copyStatus == kCMBlockBufferNoErr else {
        free(storage)
        debugLog("Encoded CMBlockBuffer copy failed: \(copyStatus)")
        return
    }

    // Rewrite the length words while the frame still lives in raw malloc
    // storage. Data adopts the already-finished bytes afterwards, so Foundation
    // copy-on-write can never turn boundary mutation into another frame copy.
    guard AnnexBConverter.rewriteFourByteLengthPrefixes(
        bytes: storage,
        count: finalSize,
        payloadOffset: payloadOffset
    ) else {
        free(storage)
        debugLog("Encoded frame contained malformed 4-byte NAL lengths — dropping frame")
        return
    }

    let frameData = Data(bytesNoCopy: storage, count: finalSize, deallocator: .free)
    encoder.onEncodedFrame?(frameData, timestamp, isKeyframe)
}
