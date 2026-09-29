import Foundation

/// Annex-B NAL unit reader used to verify what `VideoEncoder` actually put on
/// the wire. This is the single implementation of this logic in the repository;
/// it used to live only in the now-deleted `MacHost/StreamTest` harness, where
/// nothing built, linted or tested it.
///
/// Pure functions over `Data` so the whole thing is unit-testable.
enum HEVCNALInspector {

    struct NALUnit {
        let type: Int
        let name: String
        let offset: Int
        let size: Int
    }

    /// A start code is 3 or 4 bytes; only the 4-byte form is emitted by
    /// `VideoEncoder`, but 3-byte sequences are legal Annex-B and appear in
    /// files written by other tools, so both are recognised.
    private static let longStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private static let shortStartCode: [UInt8] = [0x00, 0x00, 0x01]

    /// HEVC NAL unit header: forbidden_zero_bit(1) | nal_unit_type(6) |
    /// nuh_layer_id(6) | nuh_temporal_id_plus1(3).
    ///
    /// H.264 uses forbidden_zero_bit(1) | nal_ref_idc(2) | nal_unit_type(5),
    /// so the same shift/mask yields garbage there. `names(for:)` is therefore
    /// HEVC-only by design.
    static func hevcType(ofFirstHeaderByte byte: UInt8) -> Int {
        Int((byte >> 1) & 0x3F)
    }

    static func name(forType type: Int) -> String {
        switch type {
        case 32: return "VPS (Video Parameter Set)"
        case 33: return "SPS (Sequence Parameter Set)"
        case 34: return "PPS (Picture Parameter Set)"
        case 35: return "AUD (Access Unit Delimiter)"
        case 19, 20: return "IDR (Keyframe)"
        case 1: return "P-slice (Non-IDR)"
        case 0, 2: return "TRAIL_N (Non-IDR)"
        case 36: return "EOS (End of Sequence)"
        case 37: return "EOB (End of Bitstream)"
        case 38: return "FD (Filler Data)"
        case 39: return "SEI (Prefix)"
        case 40: return "SEI (Suffix)"
        default: return "Type \(type)"
        }
    }

    /// Walks the Annex-B byte stream, resynchronising on start codes so leading
    /// or inter-NAL garbage is tolerated rather than mis-parsed.
    static func units(in data: Data) -> [NALUnit] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }

        // Locate every start code up front so each NAL's length is simply the
        // distance to the next one. This avoids the O(n^2) rescan the original
        // harness did, and it makes the "trailing partial NAL" case explicit.
        var starts: [(offset: Int, length: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if i + 4 <= bytes.count,
               bytes[i] == longStartCode[0], bytes[i + 1] == longStartCode[1],
               bytes[i + 2] == longStartCode[2], bytes[i + 3] == longStartCode[3] {
                starts.append((i + 4, 4))
                i += 4
            } else if bytes[i] == shortStartCode[0], bytes[i + 1] == shortStartCode[1],
                      bytes[i + 2] == shortStartCode[2] {
                starts.append((i + 3, 3))
                i += 3
            } else {
                i += 1
            }
        }

        var result: [NALUnit] = []
        for (index, start) in starts.enumerated() {
            // A start code with no header byte after it is not a NAL unit.
            guard start.offset < bytes.count else { continue }
            let end = index + 1 < starts.count ? starts[index + 1].offset - starts[index + 1].length : bytes.count
            let size = end - start.offset
            guard size > 0 else { continue }
            let type = hevcType(ofFirstHeaderByte: bytes[start.offset])
            result.append(NALUnit(type: type, name: name(forType: type), offset: start.offset, size: size))
        }
        return result
    }

    static func summary(of data: Data) -> String {
        let units = units(in: data)
        guard !units.isEmpty else { return "  No NAL units found (\(data.count) bytes)" }
        var lines = units.enumerated().map { index, unit in
            "  NAL #\(index): \(unit.name), \(unit.size) bytes"
        }
        lines.append("  Total NAL units: \(units.count)")
        return lines.joined(separator: "\n")
    }
}
