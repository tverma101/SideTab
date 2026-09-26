import CoreMedia
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
        let input = lengthPrefixed([[0x40, 0x01], [0x42, 0x02, 0x03], [0x26, 0x04]])
        XCTAssertEqual(
            Array(annexB(input)),
            startCode + [0x40, 0x01] + startCode + [0x42, 0x02, 0x03] + startCode + [0x26, 0x04]
        )
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

    /// Fail-closed keyframe detection. CMSampleBuffer's attachment array is the
    /// only evidence, and anything other than an explicit NotSync=false means
    /// "not a sync sample": announcing a P-frame as an IDR melts bandwidth and
    /// disarms the client's stale-keyframe watchdog.
    func testKeyframeDetectionFailsClosed() {
        XCTAssertTrue(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: false]]))
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: true]]))
        // Missing evidence of any kind.
        XCTAssertFalse(isSyncSample(attachments: nil))
        XCTAssertFalse(isSyncSample(attachments: []))
        XCTAssertFalse(isSyncSample(attachments: [[:]]))
        // Wrong type for the key.
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: "false"]]))
        XCTAssertFalse(isSyncSample(attachments: [[kCMSampleAttachmentKey_NotSync: 0]]))
    }

    private func isSyncSample(attachments: [[CFString: Any]]?) -> Bool {
        VideoEncoder.isSyncSample(attachments: attachments)
    }
}
