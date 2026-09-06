import Foundation

/// Rewrites VideoToolbox's 4-byte big-endian NAL length prefixes into 4-byte
/// Annex-B start codes without moving or recopying NAL payload bytes.
///
/// The transform is size-preserving: both representations use four bytes per
/// NAL boundary. Callers can therefore bulk-copy an encoded CMBlockBuffer once
/// into its final Data storage and mutate only the boundary words in place.
enum AnnexBConverter {
    static func rewriteFourByteLengthPrefixes(
        in data: inout Data,
        payloadOffset: Int = 0
    ) -> Bool {
        guard payloadOffset >= 0, payloadOffset <= data.count else { return false }
        let end = data.count
        guard payloadOffset < end else { return false }

        return data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = payloadOffset

            while offset < end {
                guard end - offset >= 4 else { return false }

                let nalLength =
                    (Int(base[offset]) << 24) |
                    (Int(base[offset + 1]) << 16) |
                    (Int(base[offset + 2]) << 8) |
                    Int(base[offset + 3])
                let payloadStart = offset + 4
                guard nalLength > 0, nalLength <= end - payloadStart else { return false }

                base[offset] = 0
                base[offset + 1] = 0
                base[offset + 2] = 0
                base[offset + 3] = 1
                offset = payloadStart + nalLength
            }

            return offset == end
        }
    }
}
