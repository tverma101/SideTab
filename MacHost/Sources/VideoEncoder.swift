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

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let expProfile = UserDefaults.standard.string(forKey: "SideScreen_exp_profile")
        let hdrMode = UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr")
        let profile: CFString = codec == .hevc
            ? (hdrMode || expProfile == "main10" ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : (expProfile == "main42210" ? kVTProfileLevel_HEVC_Main42210_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel))
            : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        let presetMbps: Int
        switch quality {
        case "ultralow": presetMbps = 6
        case "low": presetMbps = 12
        case "medium": presetMbps = 20
        case "high": presetMbps = 30
        case "extrahigh": presetMbps = 40
        case "max": presetMbps = 50
        case "ultra": presetMbps = 60
        default: presetMbps = 20
        }

        let expBitrate = UserDefaults.standard.object(forKey: "SideScreen_exp_bitrate") as? Int
        let connectionMode = UserDefaults.standard.string(forKey: "SideScreen_connectionMode") ?? "usb"
        let isWireless = connectionMode == "wireless"
        let uiFloor = (!isWireless && bitrateMbps >= 100 && bitrateMbps <= 2000) ? bitrateMbps : 0
        let targetMbps = expBitrate ?? ((gamingBoost || isWireless) ? presetMbps : max(presetMbps, uiFloor))
        let avgBps = targetMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBps as CFNumber)

        let capBytes = Int(Double(targetMbps) * 1.5 * 1_000_000.0 / 8.0)
        let dataRateLimits = [capBytes, 1] as CFArray
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        debugLog("Rate control: path=\(isWireless ? "wireless" : "usb") avg=\(targetMbps)Mbps cap=\(Int(Double(targetMbps) * 1.5))Mbps/1s (DataRateLimits status=\(limitStatus))")

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        let expGop = UserDefaults.standard.object(forKey: "SideScreen_exp_gop") as? Int
        let defaultGopFrames = frameRate * (isWireless ? 5 : 1)
        let gopFrames = expGop ?? defaultGopFrames
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(gopFrames) / Double(frameRate) as CFNumber)

        let expBFrames = UserDefaults.standard.object(forKey: "SideScreen_exp_bframes") as? Bool ?? false
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: (expBFrames ? kCFBooleanTrue : kCFBooleanFalse))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

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

    func requestKeyframe() {
        let pressureGeneration = WirelessTransportPressure.noteForcedCapturePending()
        stateLock.withLock { state in
            state.pendingForceKeyframe = true
            state.pendingForcePressureGeneration = pressureGeneration
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }

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

private let nalStartCode: [UInt8] = [0, 0, 0, 1]
private let plausibleFrameAgeNs: UInt64 = 60_000_000_000

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

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    var parameterPrefix = Data(capacity: isKeyframe ? 256 : 0)

    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
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

    var frameData = Data(bytesNoCopy: storage, count: finalSize, deallocator: .free)
    guard AnnexBConverter.rewriteFourByteLengthPrefixes(
        in: &frameData,
        payloadOffset: payloadOffset
    ) else {
        debugLog("Encoded frame contained malformed 4-byte NAL lengths — dropping frame")
        return
    }

    encoder.onEncodedFrame?(frameData, timestamp, isKeyframe)
}
