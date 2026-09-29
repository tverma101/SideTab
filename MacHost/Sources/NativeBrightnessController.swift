import Foundation

/// Persisted tablet brightness shared by the compact menu-bar control and the
/// streaming connection. The value is retained while the tablet is offline;
/// the active server replays it when the Android client negotiates BRIGHT.
///
/// This controller intentionally has no per-frame work and no global keyboard
/// event tap. Brightness changes are explicit menu interactions, so keeping
/// the hot path to one persisted byte and one control-channel message avoids
/// adding input-monitoring overhead to the streaming app.
final class NativeBrightnessController {
    static let defaultsKey = "SideScreen_virtualBrightness"
    static let maximumLevel: Int = 255
    static let minimumLevel: Int = 8

    var onBrightness: ((UInt8) -> Void)?

    private let lock = NSLock()
    private var currentLevel: Int

    init() {
        currentLevel = Self.persistedLevel
    }

    var level: UInt8 {
        lock.lock()
        defer { lock.unlock() }
        return UInt8(currentLevel)
    }

    static var persistedLevel: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil else {
            return maximumLevel
        }
        let saved = defaults.integer(forKey: defaultsKey)
        return clampedLevel(saved == 0 ? maximumLevel : saved)
    }

    static func clampedLevel(_ rawLevel: Int) -> Int {
        max(minimumLevel, min(maximumLevel, rawLevel))
    }

    static func normalizedValue(for level: UInt8) -> Double {
        Double(Int(level)) / Double(maximumLevel)
    }

    static func level(forNormalizedValue value: Double) -> UInt8 {
        let raw = Int((value * Double(maximumLevel)).rounded())
        return UInt8(clampedLevel(raw))
    }

    /// Apply a value from the menu bar and notify the active stream.
    @discardableResult
    func setLevel(_ level: UInt8) -> UInt8 {
        let value = Self.clampedLevel(Int(level))
        let changed: Bool

        lock.lock()
        changed = value != currentLevel
        if changed {
            currentLevel = value
            UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        }
        lock.unlock()

        if changed {
            onBrightness?(UInt8(value))
        }
        return UInt8(value)
    }

    /// Replay the persisted value after a new Android client connects.
    func pushCurrent() {
        onBrightness?(level)
    }
}
