import Foundation

/// Rewrites VideoToolbox's 4-byte big-endian NAL length prefixes into 4-byte
/// Annex-B start codes without moving or recopying NAL payload bytes.
///
/// The transform is size-preserving: both representations use four bytes per
/// NAL boundary. The raw-storage entry point lets VideoEncoder bulk-copy a
/// CMBlockBuffer once, rewrite only boundary words, and wrap the finished bytes
/// in Data afterwards so copy-on-write can never add another frame-sized copy.
enum AnnexBConverter {
    static func rewriteFourByteLengthPrefixes(
        bytes: UnsafeMutableRawPointer,
        count: Int,
        payloadOffset: Int = 0
    ) -> Bool {
        guard payloadOffset >= 0, payloadOffset < count else { return false }
        let base = bytes.assumingMemoryBound(to: UInt8.self)
        var offset = payloadOffset

        while offset < count {
            guard count - offset >= 4 else { return false }

            let nalLength =
                (Int(base[offset]) << 24) |
                (Int(base[offset + 1]) << 16) |
                (Int(base[offset + 2]) << 8) |
                Int(base[offset + 3])
            let payloadStart = offset + 4
            guard nalLength > 0, nalLength <= count - payloadStart else { return false }

            base[offset] = 0
            base[offset + 1] = 0
            base[offset + 2] = 0
            base[offset + 3] = 1
            offset = payloadStart + nalLength
        }

        return offset == count
    }

    /// Data convenience used by unit tests and non-hot callers. The encoder's
    /// output callback uses the raw-storage overload above before Data exists.
    static func rewriteFourByteLengthPrefixes(
        in data: inout Data,
        payloadOffset: Int = 0
    ) -> Bool {
        guard payloadOffset >= 0, payloadOffset < data.count else { return false }
        return data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            return rewriteFourByteLengthPrefixes(
                bytes: base,
                count: rawBuffer.count,
                payloadOffset: payloadOffset
            )
        }
    }
}
