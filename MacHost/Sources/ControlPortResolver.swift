import Foundation

enum ControlPortResolver {
    static let defaultsKey = "SideScreen_controlPort"

    /// Ports at or below this are privileged: a non-root app cannot bind one,
    /// so an override there is always a mistake and silently disables control.
    static let privilegedPortCeiling = 1023

    /// Valid explicit override for `videoPort`, or nil when unset/malformed.
    ///
    /// Rejects anything a `defaults write` knob can produce that would either
    /// trap (UInt16(exactly:) is exact, UInt16(Int) traps above 65535) or
    /// silently break the session: a privileged port, and a control port equal
    /// to the video port — both listeners would then contend for one port, and
    /// one of them becomes a permanent black hole. Passing `videoPort` is what
    /// makes the self-collision check possible; omitting it skips that check.
    static func explicitOverride(
        videoPort: UInt16? = nil,
        defaults: UserDefaults = .standard
    ) -> UInt16? {
        let raw = defaults.integer(forKey: defaultsKey)
        guard raw > privilegedPortCeiling, let port = UInt16(exactly: raw) else { return nil }
        if let videoPort, port == videoPort { return nil }
        return port
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
        if let override = explicitOverride(videoPort: videoPort, defaults: defaults) {
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
