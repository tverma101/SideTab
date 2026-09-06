import XCTest
@testable import SideScreen

final class AnnexBConverterTests: XCTestCase {
    private func lengthPrefixed(_ payloads: [[UInt8]]) -> Data {
        var data = Data()
        for payload in payloads {
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: payload)
        }
        return data
    }

    func testRewritesSingleNalWithoutMovingPayload() {
        var data = lengthPrefixed([[0x26, 0x01, 0xAA, 0xBB]])

        XCTAssertTrue(AnnexBConverter.rewriteFourByteLengthPrefixes(in: &data))
        XCTAssertEqual(data, Data([0, 0, 0, 1, 0x26, 0x01, 0xAA, 0xBB]))
    }

    func testRewritesMultipleNalsInPlace() {
        var data = lengthPrefixed([
            [0x02, 0x01, 0x10],
            [0x28, 0x01, 0x20, 0x21, 0x22],
            [0x4E, 0x01],
        ])

        XCTAssertTrue(AnnexBConverter.rewriteFourByteLengthPrefixes(in: &data))
        XCTAssertEqual(
            data,
            Data([
                0, 0, 0, 1, 0x02, 0x01, 0x10,
                0, 0, 0, 1, 0x28, 0x01, 0x20, 0x21, 0x22,
                0, 0, 0, 1, 0x4E, 0x01,
            ])
        )
    }

    func testRawStorageRewriteMatchesDataPath() {
        var data = lengthPrefixed([
            [0x02, 0x01, 0x10],
            [0x28, 0x01, 0x20, 0x21],
        ])

        let rewritten = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            return AnnexBConverter.rewriteFourByteLengthPrefixes(
                bytes: base,
                count: bytes.count
            )
        }

        XCTAssertTrue(rewritten)
        XCTAssertEqual(
            data,
            Data([
                0, 0, 0, 1, 0x02, 0x01, 0x10,
                0, 0, 0, 1, 0x28, 0x01, 0x20, 0x21,
            ])
        )
    }

    func testPayloadOffsetPreservesPrependedParameterSets() {
        let prefix = Data([0, 0, 0, 1, 0x40, 0x01, 0x0C])
        var data = prefix
        data.append(lengthPrefixed([[0x26, 0x01, 0x99]]))

        XCTAssertTrue(
            AnnexBConverter.rewriteFourByteLengthPrefixes(
                in: &data,
                payloadOffset: prefix.count
            )
        )
        XCTAssertEqual(data.prefix(prefix.count), prefix)
        XCTAssertEqual(data.suffix(7), Data([0, 0, 0, 1, 0x26, 0x01, 0x99]))
    }

    func testRejectsTruncatedLengthPrefix() {
        var data = Data([0, 0, 4])
        XCTAssertFalse(AnnexBConverter.rewriteFourByteLengthPrefixes(in: &data))
    }

    func testRejectsNalLengthPastEnd() {
        var data = Data([0, 0, 0, 8, 0x26, 0x01])
        XCTAssertFalse(AnnexBConverter.rewriteFourByteLengthPrefixes(in: &data))
    }

    func testRejectsZeroLengthNal() {
        var data = Data([0, 0, 0, 0])
        XCTAssertFalse(AnnexBConverter.rewriteFourByteLengthPrefixes(in: &data))
    }
}
