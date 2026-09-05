import Foundation

enum ControlPortResolver {
    static let defaultsKey = "SideScreen_controlPort"

    /// Valid explicit override, or nil when unset/malformed.
    static func explicitOverride(defaults: UserDefaults = .standard) -> UInt16? {
        let raw = defaults.integer(forKey: defaultsKey)
        guard raw > 0 else { return nil }
        return UInt16(exactly: raw)
    }

    /// Effective dedicated control port for a video listener.
    ///
    /// The normal convention is video+1. UInt16.max has no +1 neighbour, so
    /// use max-1 at that single boundary. QR generation will explicitly encode
    /// that nonstandard pairing so Android never has to guess it.
    static func effective(
        videoPort: UInt16,
        defaults: UserDefaults = .standard
    ) -> UInt16 {
        if let override = explicitOverride(defaults: defaults) {
            return override
        }
        return videoPort == UInt16.max ? UInt16.max - 1 : videoPort + 1
    }

    /// Port that must be carried in the QR. nil preserves the legacy/default
    /// QR when control is exactly video+1.
    static func qrOverride(
        videoPort: UInt16,
        defaults: UserDefaults = .standard
    ) -> UInt16? {
        let effectivePort = effective(videoPort: videoPort, defaults: defaults)
        if videoPort < UInt16.max && effectivePort == videoPort + 1 {
            return nil
        }
        return effectivePort
    }
}
