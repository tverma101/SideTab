import XCTest
@testable import SideScreen

/// `HEVCNALInspector` is the repo's only Annex-B *reader*. It replaces the
/// `analyzeNALUnits` helper that used to live in the unbuilt `StreamTest`
/// harness, so the parser finally has real coverage.
final class HEVCNALInspectorTests: XCTestCase {

    /// Builds a 4-byte-start-code NAL with the given HEVC nal_unit_type.
    private func nal(_ type: Int, payloadBytes: Int = 4) -> Data {
        var out = Data([0x00, 0x00, 0x00, 0x01])
        out.append(UInt8((type << 1) & 0xFF))
        out.append(contentsOf: [UInt8](repeating: 0xAA, count: payloadBytes))
        return out
    }

    func testHevcTypeExtraction() {
        // nal_unit_type occupies bits 1..6 of the first header byte.
        XCTAssertEqual(HEVCNALInspector.hevcType(ofFirstHeaderByte: UInt8(32 << 1)), 32)
        XCTAssertEqual(HEVCNALInspector.hevcType(ofFirstHeaderByte: UInt8(1 << 1)), 1)
        XCTAssertEqual(HEVCNALInspector.hevcType(ofFirstHeaderByte: 0x00), 0)
        XCTAssertEqual(HEVCNALInspector.hevcType(ofFirstHeaderByte: 0xFF), 63)
        // nuh_layer_id / nuh_temporal_id_plus1 bits must not leak into the type.
        XCTAssertEqual(HEVCNALInspector.hevcType(ofFirstHeaderByte: 0b1111_1101), 62)
    }

    func testParameterSetNames() {
        XCTAssertEqual(HEVCNALInspector.name(forType: 32), "VPS (Video Parameter Set)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 33), "SPS (Sequence Parameter Set)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 34), "PPS (Picture Parameter Set)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 19), "IDR (Keyframe)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 20), "IDR (Keyframe)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 39), "SEI (Prefix)")
        XCTAssertEqual(HEVCNALInspector.name(forType: 40), "SEI (Suffix)")
    }

    func testUnknownTypeFallsBackToNumericName() {
        XCTAssertEqual(HEVCNALInspector.name(forType: 7), "Type 7")
        XCTAssertEqual(HEVCNALInspector.name(forType: 63), "Type 63")
    }

    func testParsesIDRWithParameterSets() {
        // A real keyframe is VPS + SPS + PPS + IDR in that order.
        var data = Data()
        data.append(nal(32, payloadBytes: 10))
        data.append(nal(33, payloadBytes: 20))
        data.append(nal(34, payloadBytes: 8))
        data.append(nal(19, payloadBytes: 100))

        let units = HEVCNALInspector.units(in: data)
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(units.map(\.type), [32, 33, 34, 19])
        XCTAssertEqual(units[0].name, "VPS (Video Parameter Set)")
        XCTAssertEqual(units[3].name, "IDR (Keyframe)")
        // payload + 1 header byte
        XCTAssertEqual(units.map(\.size), [11, 21, 9, 101])
    }

    func testNALSizeIsDistanceToNextStartCode() {
        var data = Data()
        data.append(nal(33, payloadBytes: 12))
        data.append(nal(19, payloadBytes: 50))
        let units = HEVCNALInspector.units(in: data)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].size, 13)
        XCTAssertEqual(units[1].size, 51)
        XCTAssertLessThan(units[0].offset, units[1].offset)
    }

    func testLeadingGarbageIsResynchronised() {
        var data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        data.append(nal(33, payloadBytes: 6))
        let units = HEVCNALInspector.units(in: data)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].type, 33)
        XCTAssertEqual(units[0].offset, 8, "payload must start after the 4-byte start code")
    }

    func testThreeByteStartCodeIsRecognised() {
        var data = Data([0x00, 0x00, 0x01])
        data.append(UInt8(33 << 1))
        data.append(contentsOf: [UInt8](repeating: 0, count: 5))
        let units = HEVCNALInspector.units(in: data)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].type, 33)
        XCTAssertEqual(units[0].size, 6)
    }

    func testEmptyAndTooShortInputsAreSafe() {
        // The original harness computed `bytes.count - 4` unguarded, which
        // traps for counts 0...3.
        XCTAssertTrue(HEVCNALInspector.units(in: Data()).isEmpty)
        XCTAssertTrue(HEVCNALInspector.units(in: Data([0x00])).isEmpty)
        XCTAssertTrue(HEVCNALInspector.units(in: Data([0x00, 0x00, 0x00])).isEmpty)
        XCTAssertTrue(HEVCNALInspector.units(in: Data([0x00, 0x00, 0x00, 0x01])).isEmpty)
    }

    func testTrailingStartCodeWithoutPayloadIsSkipped() {
        var data = nal(33, payloadBytes: 4)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        let units = HEVCNALInspector.units(in: data)
        XCTAssertEqual(units.count, 1, "a start code with no NAL byte after it is not a unit")
        XCTAssertEqual(units[0].type, 33)
    }

    func testSummaryMentionsEveryUnitAndTotal() {
        var data = Data()
        data.append(nal(32, payloadBytes: 2))
        data.append(nal(19, payloadBytes: 3))
        let text = HEVCNALInspector.summary(of: data)
        XCTAssertTrue(text.contains("NAL #0: VPS (Video Parameter Set)"))
        XCTAssertTrue(text.contains("NAL #1: IDR (Keyframe)"))
        XCTAssertTrue(text.contains("Total NAL units: 2"))
    }

    func testSummaryOfGarbageReportsNoUnits() {
        let text = HEVCNALInspector.summary(of: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        XCTAssertTrue(text.contains("No NAL units found"))
    }
}
