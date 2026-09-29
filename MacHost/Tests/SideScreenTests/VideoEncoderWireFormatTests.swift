import CoreMedia
import os
import VideoToolbox
import XCTest
@testable import SideScreen

/// The Annex-B writer and the sync-sample decision are the two places where a
/// malformed input used to become an out-of-bounds read or a bogus "IDR" on the
/// wire. Both are extracted into testable units.
final class VideoEncoderWireFormatTests: XCTestCase {
    private let startCode: [UInt8] = [0, 0, 0, 1]

    private func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: nal)
        }
        return bytes
    }

    private func annexB(_ bytes: [UInt8]) -> Data {
        var out = Data()
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            VideoEncoder.appendAnnexBFrame(from: UnsafeRawPointer(base), totalLength: bytes.count, into: &out)
        }
        return out
    }

    func testWellFormedLengthPrefixedFrameBecomesAnnexB() {
        let nals: [[UInt8]] = [[0x40, 0x01], [0x42, 0x02, 0x03], [0x26, 0x04]]
        let input = lengthPrefixed(nals)
        // Built with flatMap: a six-term `+` chain of literals is too slow for
        // the Swift 5.10 type checker on the CI toolchain.
        let expected = nals.flatMap { startCode + $0 }
        XCTAssertEqual(Array(annexB(input)), expected)
    }

    func testEmptyFrameProducesNothing() {
        XCTAssertEqual(annexB([]).count, 0)
    }

    /// A length word with fewer than 4 bytes left must stop the walk, not read
    /// past the block buffer.
    func testTruncatedLengthPrefixTruncatesInsteadOfReadingPastTheEnd() {
        var input = lengthPrefixed([[0x40, 0x01], [0x42, 0x02]])
        input.append(contentsOf: [0x00, 0x00])  // 2 stray bytes, no length word
        let out = Array(annexB(input))
        XCTAssertEqual(out, startCode + [0x40, 0x01] + startCode + [0x42, 0x02])
    }

    /// The original walk would have memcpy'd this 0xFFFFFFF0 length and appended
    /// ~4 GiB from whatever followed in memory.
    func testCorruptLengthWordTruncatesInsteadOfOverReading() {
        var input = lengthPrefixed([[0x40, 0x01]])
        input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xF0])  // 4,294,967,280 bytes
        input.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])
        let out = Array(annexB(input))
        XCTAssertEqual(out, startCode + [0x40, 0x01])
    }

    func testLengthWordLargerThanRemainderByOneStops() {
        var input: [UInt8] = []
        var length = UInt32(9).bigEndian  // 9 bytes promised, 5 present
        withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        input.append(contentsOf: [1, 2, 3, 4, 5])
        XCTAssertEqual(annexB(input).count, 0)
    }

    func testZeroLengthNALIsEmittedAsABareStartCode() {
        let out = Array(annexB(lengthPrefixed([[], [0x40, 0x01]])))
        XCTAssertEqual(out, startCode + startCode + [0x40, 0x01])
    }

    // MARK: - Sync sample decision

    /// CoreMedia defines a missing NotSync key as a sync sample, and that is
    /// exactly how VideoToolbox marks its IDRs.
    func testKeyframeDetectionFollowsCoreMediaContract() {
        XCTAssertTrue(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: false]]))
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: true]]))
        // VideoToolbox's real attachments, as observed from an HEVC and an
        // H.264 session: an IDR omits NotSync, a P-frame sets it.
        XCTAssertTrue(isSyncSample(attachments: [[kCMSampleAttachmentKey_DependsOnOthers: false]]))
        XCTAssertFalse(isSyncSample(attachments: [[
            kCMSampleAttachmentKey_DependsOnOthers: true,
            kCMSampleAttachmentKey_NotSync: true,
        ]]))
        // No NotSync key anywhere: absence implies sync.
        XCTAssertTrue(isSyncSample(attachments: nil))
        XCTAssertTrue(isSyncSample(attachments: []))
        XCTAssertTrue(isSyncSample(attachments: [[:]]))
        // A present key with the wrong type is malformed, not absent.
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: "false"]]))
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: 0]]))
    }

    /// End to end through VideoToolbox: a fresh session's first output is an
    /// IDR, and it has to leave the encoder flagged as one, with its parameter
    /// sets in front. When this regressed, every keyframe was reported as a
    /// P-frame and the host sent no video at all.
    func testRealEncoderFlagsItsFirstFrameAsKeyframe() throws {
        let width = 320
        let height = 192
        // Hosted CI runners are VMs with no hardware encoder; there VideoToolbox
        // still creates a session but never delivers a frame.
        try XCTSkipUnless(
            Self.hasHardwareEncoder(width: width, height: height),
            "no hardware H.264 encoder on this machine"
        )
        let encoder = VideoEncoder(width: width, height: height, codec: .h264, frameRate: 30)
        let output = OSAllocatedUnfairLock<(data: Data, isKeyframe: Bool)?>(initialState: nil)
        let delivered = expectation(description: "first encoded frame")
        encoder.onEncodedFrame = { data, _, isKeyframe in
            let isFirst = output.withLock { state -> Bool in
                guard state == nil else { return false }
                state = (data, isKeyframe)
                return true
            }
            if isFirst { delivered.fulfill() }
        }

        let pixelBuffer = try XCTUnwrap(Self.makePixelBuffer(width: width, height: height))
        encoder.encode(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1_000),
                timescale: 1_000_000
            )
        )
        wait(for: [delivered], timeout: 5)
        encoder.onEncodedFrame = nil

        let first = try XCTUnwrap(output.withLock { $0 })
        XCTAssertTrue(first.isKeyframe, "a session's first frame is an IDR and must be flagged as one")
        // Parameter sets are prepended only to keyframes: the first NAL unit
        // after the leading start code must be an H.264 SPS (type 7).
        let bytes = Array(first.data.prefix(5))
        XCTAssertEqual(Array(bytes.prefix(4)), startCode)
        XCTAssertEqual(bytes.count == 5 ? bytes[4] & 0x1F : nil, 7)
    }

    private static func hasHardwareEncoder(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        return buffer
    }

    private func isSyncSample(attachments: [[CFString: Any]]?) -> Bool {
        VideoEncoder.isSyncSample(attachments: attachments)
    }
}
