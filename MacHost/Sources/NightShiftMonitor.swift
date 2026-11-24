import Foundation

/// One sample of the host's Night Shift state, as CoreBrightness reports it.
struct NightShiftReading: Equatable {
    /// True while Night Shift is actually warming the display: the status
    /// struct's `active` bit, not `enabled`. A scheduled Night Shift during
    /// the day is enabled but inactive, and the panel shows neutral color.
    let active: Bool
    /// Night Shift warmth 0...1 (0 = "Less Warm" end of the slider).
    let strength: Float
    /// Reported color temperature in Kelvin. Diagnostics only.
    let kelvin: Float
}

/// What the tablet's own blue-light filter should show.
struct NightShiftTarget: Equatable {
    var enabled: Bool
    /// Samsung Eye comfort shield level, 0...`maximumLevel`.
    var level: Int

    /// The Eye comfort shield "Color temperature" slider writes 0...10 to
    /// `blue_light_filter_opacity` (measured on SM-X800, One UI / Android 14:
    /// slider far left = 0, far right = 10). Values above 10 are outside the
    /// panel's table, which is why a 0...100 mapping never tracked the Mac.
    static let maximumLevel = 10

    static let off = NightShiftTarget(enabled: false, level: 0)

    /// Night Shift strength 0...1 -> slider level, rounded and clamped.
    /// Non-finite input maps to 0 rather than trapping in `Int(_:)`.
    static func level(forStrength strength: Float) -> Int {
        guard strength.isFinite else { return 0 }
        let unit = min(max(strength, 0), 1)
        return Int((unit * Float(maximumLevel)).rounded())
    }

    /// Fail closed: an unreadable probe means "off", so a broken detection
    /// path can never strand a warm filter on the tablet.
    static func target(for reading: NightShiftReading?) -> NightShiftTarget {
        guard let reading, reading.active else { return .off }
        return NightShiftTarget(enabled: true, level: level(forStrength: reading.strength))
    }
}

/// Reads the host's live Night Shift state through CoreBrightness' private
/// `CBBlueLightClient`, resolved at runtime and never linked. A macOS that
/// renames or removes the API leaves the probe nil, which the monitor reports
/// as "off" instead of guessing.
///
/// Verified on macOS 27.2: `supportsBlueLightReduction` = 1,
/// `getStrength:` = 0.883 and `getCCT:` = 3028 K while Night Shift is on.
final class BlueLightStatusProbe {
    /// Layout of the out-struct, matching the runtime type encoding
    /// `{?=BBBi{?={?=ii}{?=ii}}QB}` (40 bytes; checked with clang's sizeof).
    private struct CBBlueLightStatus {
        var active: UInt8 = 0
        var enabled: UInt8 = 0
        var sunSchedulePermitted: UInt8 = 0
        var mode: Int32 = 0
        var fromHour: Int32 = 0
        var fromMinute: Int32 = 0
        var toHour: Int32 = 0
        var toMinute: Int32 = 0
        var disableFlags: UInt64 = 0
        var available: UInt8 = 0
    }

    private typealias BoolFn = @convention(c) (AnyObject, Selector) -> UInt8
    private typealias OutParamFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> UInt8

    private let client: NSObject
    private let statusSel = NSSelectorFromString("getBlueLightStatus:")
    private let strengthSel = NSSelectorFromString("getStrength:")
    private let cctSel = NSSelectorFromString("getCCT:")
    private let statusFn: OutParamFn
    private let strengthFn: OutParamFn?
    private let cctFn: OutParamFn?

    init?() {
        guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else { return nil }

        let supportedSel = NSSelectorFromString("supportsBlueLightReduction")
        guard let supportedImp = (cls as AnyObject).method(for: supportedSel),
              unsafeBitCast(supportedImp, to: BoolFn.self)(cls, supportedSel) != 0
        else { return nil }

        let client = cls.init()
        guard let statusImp = client.method(for: statusSel) else { return nil }
        self.client = client
        statusFn = unsafeBitCast(statusImp, to: OutParamFn.self)
        strengthFn = client.method(for: strengthSel).map { unsafeBitCast($0, to: OutParamFn.self) }
        cctFn = client.method(for: cctSel).map { unsafeBitCast($0, to: OutParamFn.self) }
    }

    /// The current state, or nil when the runtime refused the status read.
    /// A missing strength selector reads as 0 rather than dropping the sample.
    func read() -> NightShiftReading? {
        var status = CBBlueLightStatus()
        let ok = withUnsafeMutablePointer(to: &status) {
            statusFn(client, statusSel, UnsafeMutableRawPointer($0))
        }
        guard ok != 0 else { return nil }
        return NightShiftReading(
            active: status.active != 0,
            strength: readFloat(strengthFn, strengthSel),
            kelvin: readFloat(cctFn, cctSel)
        )
    }

    private func readFloat(_ fn: OutParamFn?, _ sel: Selector) -> Float {
        guard let fn else { return 0 }
        var value: Float = 0
        _ = withUnsafeMutablePointer(to: &value) { fn(client, sel, UnsafeMutableRawPointer($0)) }
        return value
    }
}

/// Polls Night Shift at ~1 Hz and reports a new `NightShiftTarget` only when
/// it changes, so dragging the Mac's slider costs a handful of updates.
///
/// ScreenCaptureKit captures before the display's color transforms, so the
/// streamed picture stays neutral while the Mac's panels go warm. The tablet
/// therefore has to warm itself; `NightShiftTabletFilter` does that.
@MainActor
final class NightShiftMonitor {
    var onChange: ((NightShiftTarget) -> Void)?

    private let pollS: TimeInterval
    private let probe: () -> NightShiftReading?
    private var timer: Timer?
    private var lastEmitted: NightShiftTarget?
    private var lastLogged: NightShiftReading?
    private var reportedUnavailable = false

    private static let sharedProbe = BlueLightStatusProbe()

    init(pollS: TimeInterval = 1.0, probe: (() -> NightShiftReading?)? = nil) {
        self.pollS = pollS
        self.probe = probe ?? { NightShiftMonitor.sharedProbe?.read() }
    }

    /// Emits the current state immediately, then on every change. The timer
    /// goes on the main run loop in `.common` mode so it keeps firing while a
    /// menu is open.
    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: pollS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops polling and forgets the last value, so the next `start()`
    /// re-emits the current state even if it has not changed.
    func stop() {
        timer?.invalidate()
        timer = nil
        lastEmitted = nil
    }

    func tick() {
        let reading = probe()
        if let reading, reading != lastLogged {
            lastLogged = reading
            debugLog(String(
                format: "NightShift: active=%d strength=%.3f (~%.0fK)",
                reading.active ? 1 : 0, reading.strength, reading.kelvin
            ))
        } else if reading == nil, !reportedUnavailable {
            reportedUnavailable = true
            debugLog("NightShift: status unavailable, treating as off")
        }

        let target = NightShiftTarget.target(for: reading)
        guard target != lastEmitted else { return }
        lastEmitted = target
        onChange?(target)
    }
}

/// Ties the Night Shift mirror to the streaming session: the tablet follows
/// the Mac while a client is connected and gets its own Eye comfort settings
/// back afterwards.
///
/// Default on. Opt out with
/// `defaults write com.sidescreen.app SideScreen_exp_nightLight -bool false`.
@MainActor
final class NightShiftMirror {
    nonisolated static let defaultsKey = "SideScreen_exp_nightLight"

    nonisolated static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    /// A Wi-Fi blip reconnects within a few seconds; waiting this long before
    /// handing the tablet back avoids flashing its filter off and on.
    nonisolated static let releaseGrace: TimeInterval = 10

    private let monitor: NightShiftMonitor
    private let filter: NightShiftTabletFilter
    private let isEnabled: () -> Bool
    private let releaseGrace: TimeInterval
    private var pendingRelease: DispatchWorkItem?
    private(set) var isMirroring = false

    init(
        monitor: NightShiftMonitor? = nil,
        filter: NightShiftTabletFilter = NightShiftTabletFilter(),
        isEnabled: @escaping () -> Bool = { NightShiftMirror.isEnabled },
        releaseGrace: TimeInterval = NightShiftMirror.releaseGrace
    ) {
        let monitor = monitor ?? NightShiftMonitor()
        self.monitor = monitor
        self.filter = filter
        self.isEnabled = isEnabled
        self.releaseGrace = releaseGrace
        monitor.onChange = { [weak filter] target in filter?.show(target) }
    }

    func clientConnected() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard isEnabled() else { return }
        if !isMirroring {
            isMirroring = true
            debugLog("NightShift: mirroring to tablet Eye comfort shield")
        }
        // Re-emits the current state, so a tablet that was re-plugged or
        // changed by hand while disconnected is brought back in line.
        monitor.stop()
        monitor.start()
    }

    /// Hand the tablet back after the grace period, unless it reconnects.
    func clientDisconnected() {
        guard isMirroring, pendingRelease == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseNow() }
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGrace, execute: work)
    }

    /// Server stopped or app quitting: hand the tablet back right away.
    func releaseNow() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard isMirroring else { return }
        isMirroring = false
        monitor.stop()
        filter.release()
    }

    /// Bounded so a wedged adb cannot hold up quitting.
    func releaseForTermination(timeout: TimeInterval = 3) {
        releaseNow()
        filter.waitUntilIdle(timeout: timeout)
    }
}
