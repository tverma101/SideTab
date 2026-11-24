import Foundation

/// One sample of the host's Night Shift state, as CoreBrightness reports it.
struct NightShiftReading: Equatable {
    /// True while Night Shift is actually warming the display. This is the
    /// status dictionary's `BlueReductionEnabled` value: CoreBrightness flips
    /// it at the native schedule boundary and for a manual toggle.
    let active: Bool
    /// `AutoBlueReductionEnabled`, kept for diagnostics only. It means the
    /// automatic schedule is armed, not that the panel is warm right now;
    /// treating it as the active state keeps the mirror on all day.
    let automaticScheduleEnabled: Bool
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

    /// nil means the host state is unknown. Unknown is deliberately not
    /// mapped to off: the mirror must not take ownership of a tablet before
    /// it has one successful CoreBrightness reading.
    static func target(for reading: NightShiftReading?) -> NightShiftTarget? {
        guard let reading else { return nil }
        guard reading.active else { return .off }
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
    /// `parseStatusDictionary:intoStruct:` maps byte one from
    /// `AutoBlueReductionEnabled` and byte two from `BlueReductionEnabled`.
    /// The historical header names those bytes `active` and `enabled`, but
    /// byte one is only the armed automatic schedule. Byte two is the live
    /// Night Shift state: verified on macOS 27.2 at a solar boundary, where
    /// byte one stayed 1 all afternoon while byte two changed 0 -> 1 exactly
    /// when CoreBrightness reached sunset.
    private struct CBBlueLightStatus {
        var automaticScheduleEnabled: UInt8 = 0
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
            active: status.enabled != 0,
            automaticScheduleEnabled: status.automaticScheduleEnabled != 0,
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
                format: "NightShift: active=%d autoSchedule=%d strength=%.3f (~%.0fK)",
                reading.active ? 1 : 0, reading.automaticScheduleEnabled ? 1 : 0,
                reading.strength, reading.kelvin
            ))
        } else if reading == nil, !reportedUnavailable {
            reportedUnavailable = true
            debugLog("NightShift: status unavailable; retaining last known state")
        }

        guard let target = NightShiftTarget.target(for: reading), target != lastEmitted else { return }
        lastEmitted = target
        onChange?(target)
    }

    /// Re-emit the current known target after an adb/control failure. If the
    /// host probe is unavailable there is intentionally nothing to enforce.
    func reconcile() {
        lastEmitted = nil
        tick()
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
    private var restoreRetry: Timer?
    private var reconciliationTimer: Timer?
    private(set) var isMirroring = false

    /// How often to retry handing back a tablet the last release missed.
    nonisolated static let restoreRetryInterval: TimeInterval = 15

    /// adb authorization and cold-start failures should heal without waiting
    /// for the next macOS Night Shift transition. Successful mirroring does
    /// not repeat writes; only a failed target is re-emitted on this cadence.
    nonisolated static let reconciliationInterval: TimeInterval = 15

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
        // A crash or a quit that timed out can leave a tablet overridden.
        // Try immediately from launch, even with the mirror opted out, then
        // keep a slow retry alive until the hand-back succeeds.
        if filter.hasPendingRestores { filter.release() }
        scheduleRestoreRetryIfNeeded()
    }

    func clientConnected(
        connectionMode: ConnectionMode,
        wirelessDeviceModel: String?,
        wirelessClientHost: String?
    ) {
        pendingRelease?.cancel()
        pendingRelease = nil
        let scope: NightShiftTabletFilter.ClientScope?
        switch connectionMode {
        case .usb:
            scope = .usb
        case .wireless:
            if let wirelessDeviceModel, let wirelessClientHost {
                scope = .wireless(deviceModel: wirelessDeviceModel, clientHost: wirelessClientHost)
            } else {
                scope = nil
            }
        }
        filter.setClientScope(scope)
        guard isEnabled() else { return }
        stopRestoreRetry()
        if !isMirroring {
            isMirroring = true
            debugLog("NightShift: mirroring to tablet Eye comfort shield")
        }
        startReconciliationTimer()
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
        stopReconciliationTimer()
        filter.release()
        filter.setClientScope(nil)
        scheduleRestoreRetryIfNeeded()
    }

    /// The release finds no tablet when the cable is already out, which
    /// would leave the tablet warm until the next session. Keep retrying
    /// while a saved setting is waiting; each try is one `adb devices`.
    private func scheduleRestoreRetryIfNeeded() {
        guard restoreRetry == nil else { return }
        let t = Timer(timeInterval: Self.restoreRetryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isMirroring, self.filter.hasPendingRestores else {
                    self.stopRestoreRetry()
                    return
                }
                self.filter.release()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        restoreRetry = t
    }

    private func stopRestoreRetry() {
        restoreRetry?.invalidate()
        restoreRetry = nil
    }

    private func startReconciliationTimer() {
        guard reconciliationTimer == nil else { return }
        let t = Timer(timeInterval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMirroring, self.filter.needsReconciliation else { return }
                self.monitor.reconcile()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reconciliationTimer = t
    }

    private func stopReconciliationTimer() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
    }

    /// Bounded so a wedged adb cannot hold up quitting.
    func releaseForTermination(timeout: TimeInterval = 3) {
        releaseNow()
        filter.waitUntilIdle(timeout: timeout)
    }
}
