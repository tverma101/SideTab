/// Video codec used for the encode session and wire stream.
enum StreamCodec {
    case hevc
    case h264

    /// Wire id used in the codecSelected (type 10) message.
    var wireId: UInt8 {
        switch self {
        case .hevc: return 0
        case .h264: return 1
        }
    }
}

enum CodecLimits {
    /// Conservative floor every AVC hardware decoder meets (H.264 level 4.x).
    /// AVC-only devices are low-end; their real cap is at or above this.
    static let avcMaxWidth = 1920
    static let avcMaxHeight = 1088

    /// Scale (width, height) down to fit within (maxWidth, maxHeight),
    /// preserving aspect ratio. The binding axis is aligned down to the
    /// macroblock grid first and the other axis is derived from the EXACT input
    /// aspect ratio: rounding each axis independently squashes the image
    /// (1872x1404 -> 1440x1088 is 0.74% narrow). The derived axis is aligned to
    /// the NEAREST multiple, then capped, so the residual aspect error is at
    /// most half a macroblock on that axis — 0.37% when it is ~1088 px, and
    /// proportionally larger when it is short (0.68% at ~715 px) — and both
    /// axes stay even, which 4:2:0 chroma subsampling requires. Sizes already
    /// within the limit pass through unchanged, alignment included.
    static func clamp(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxWidth > 0, maxHeight > 0 else {
            return (max(0, width), max(0, height))
        }
        guard width > maxWidth || height > maxHeight else {
            return (width, height)
        }
        let aspect = Double(width) / Double(height)
        let widthBinds = Double(maxWidth) / Double(width) <= Double(maxHeight) / Double(height)
        var w: Int
        var h: Int
        if widthBinds {
            w = alignedDown(maxWidth)
            h = min(alignedNear(Int((Double(w) / aspect).rounded())), alignedDown(maxHeight))
        } else {
            h = alignedDown(maxHeight)
            w = min(alignedNear(Int((Double(h) * aspect).rounded())), alignedDown(maxWidth))
        }
        return (w, h)
    }

    private static func alignedDown(_ value: Int) -> Int {
        max(alignment, (value / alignment) * alignment)
    }

    private static func alignedNear(_ value: Int) -> Int {
        let stepped = Int((Double(value) / Double(alignment)).rounded()) * alignment
        return max(alignment, stepped)
    }

    private static let alignment = 16

    /// Conservative fallback for AVC clients that report no decoder limit.
    static func clampForAvc(width: Int, height: Int) -> (width: Int, height: Int) {
        clamp(width: width, height: height, maxWidth: avcMaxWidth, maxHeight: avcMaxHeight)
    }
}
