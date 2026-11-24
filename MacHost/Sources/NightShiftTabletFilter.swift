import Foundation

/// Samsung "Eye comfort shield" state, as `Settings.System` stores it.
struct EyeComfortSettings: Equatable {
    /// `blue_light_filter`: 1 when the shield is switched on.
    var filter: Int
    /// `blue_light_filter_opacity`: the Custom color-temperature slider, 0...10.
    var level: Int
    /// `blue_light_filter_scheduled`: the "Set schedule" switch.
    var scheduled: Int
    /// `blue_light_filter_type`: 0 = Always on, 1 = custom times,
    /// 2 = sunset to sunrise (read from Samsung's BlueLightFilterService).
    var type: Int

    var dictionary: [String: Int] {
        ["filter": filter, "level": level, "scheduled": scheduled, "type": type]
    }

    init(filter: Int, level: Int, scheduled: Int, type: Int) {
        self.filter = filter
        self.level = level
        self.scheduled = scheduled
        self.type = type
    }

    init?(dictionary: [String: Int]) {
        guard let filter = dictionary["filter"], let level = dictionary["level"],
              let scheduled = dictionary["scheduled"], let type = dictionary["type"]
        else { return nil }
        self.init(filter: filter, level: level, scheduled: scheduled, type: type)
    }
}

/// Pure planning for driving Eye comfort shield with `settings put`.
///
/// Samsung's BlueLightFilterService only pushes a level to the panel
/// (`SemMdnieManager.setNightMode(on, level)`) when the shield is on AND
/// "Set schedule" is on; with type 0 that schedule reads "Always on". With
/// `scheduled=0` a level write is stored but never applied, which is why
/// the mirror owns all four keys while it is active. Verified on SM-X800:
/// type 0 + scheduled 1 makes every level write log
/// `DDI setNightMode : true, index : <level>`.
enum EyeComfortPlan {
    struct Write: Equatable {
        let key: String
        let value: Int
    }

    static let keyFilter = "blue_light_filter"
    static let keyLevel = "blue_light_filter_opacity"
    static let keyScheduled = "blue_light_filter_scheduled"
    static let keyType = "blue_light_filter_type"
    static let typeAlwaysOn = 0
    static let sideTabPackage = "com.sidescreen.app"

    /// Writes that make the shield show `level`, in an order where the last
    /// write always triggers an apply: mode keys first, then the level, then
    /// the on/schedule switches. Keys already at their value are skipped, so
    /// a strength-only change is a single level write.
    static func writes(toShow level: Int, over current: EyeComfortSettings) -> [Write] {
        let level = min(max(level, 0), NightShiftTarget.maximumLevel)
        var out: [Write] = []
        if current.type != typeAlwaysOn { out.append(Write(key: keyType, value: typeAlwaysOn)) }
        if current.level != level { out.append(Write(key: keyLevel, value: level)) }
        if current.filter != 1 { out.append(Write(key: keyFilter, value: 1)) }
        if current.scheduled != 1 { out.append(Write(key: keyScheduled, value: 1)) }
        return out
    }

    /// Restoring takes two phases with a pause between them. Phase one turns
    /// the shield off while it is still in the mirror's scheduled mode,
    /// which is the only state where Samsung's service calls
    /// `setNightMode(false)`; restoring `scheduled=0` first would leave the
    /// panel warm. Phase two puts the user's keys back, switch last.
    static func restorePhases(
        from current: EyeComfortSettings,
        to saved: EyeComfortSettings
    ) -> (off: [Write], restore: [Write]) {
        let off = current.filter != 0 ? [Write(key: keyFilter, value: 0)] : []
        var restore: [Write] = []
        if current.level != saved.level { restore.append(Write(key: keyLevel, value: saved.level)) }
        if current.type != saved.type { restore.append(Write(key: keyType, value: saved.type)) }
        if current.scheduled != saved.scheduled {
            restore.append(Write(key: keyScheduled, value: saved.scheduled))
        }
        if saved.filter != 0 { restore.append(Write(key: keyFilter, value: saved.filter)) }
        return (off, restore)
    }

    /// One `adb shell` round trip that reports everything a sync needs, as
    /// labeled lines so stray stderr text cannot shift a field.
    static let probeScript: String = {
        let header = [
            "echo serial=$(getprop ro.serialno)",
            "pm path \(sideTabPackage) >/dev/null 2>&1 && echo sidetab=1 || echo sidetab=0"
        ]
        let keys = [keyFilter, keyLevel, keyScheduled, keyType].map { key in
            "echo \(key)=$(settings get system \(key) 2>/dev/null)"
        }
        return (header + keys).joined(separator: "; ")
    }()

    struct Probe: Equatable {
        let serialNumber: String
        let hasSideTab: Bool
        /// nil on a tablet without Samsung's Eye comfort shield keys.
        let settings: EyeComfortSettings?
    }

    static func parseProbe(_ output: String) -> Probe? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let serial = fields["serial"], !serial.isEmpty,
              let sideTab = fields["sidetab"] else { return nil }
        var settings: EyeComfortSettings?
        if let filter = fields[keyFilter].flatMap({ Int($0) }),
           let level = fields[keyLevel].flatMap({ Int($0) }),
           let scheduled = fields[keyScheduled].flatMap({ Int($0) }),
           let type = fields[keyType].flatMap({ Int($0) }) {
            settings = EyeComfortSettings(filter: filter, level: level, scheduled: scheduled, type: type)
        }
        return Probe(serialNumber: serial, hasSideTab: sideTab == "1", settings: settings)
    }

    /// `&&` so the shell's exit status reports a failure of any write.
    static func script(for writes: [Write]) -> String {
        writes.map { "settings put system \($0.key) \($0.value)" }.joined(separator: " && ")
    }

    /// Ready transports from `adb devices -l`, USB first so a tablet that is
    /// also paired over Wi-Fi is driven through its cable.
    static func readySerials(fromDevicesOutput output: String) -> [String] {
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> (String, Bool)? in
            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return (String(fields[0]), fields.dropFirst(2).contains { $0.hasPrefix("usb:") })
        }
        return rows.filter { $0.1 }.map { $0.0 } + rows.filter { !$0.1 }.map { $0.0 }
    }
}

/// The user's own Eye comfort settings, saved before the mirror first takes
/// over a tablet. They live in UserDefaults so a quit or crash while Night
/// Shift is on cannot lose them; the next release restores them.
final class EyeComfortSnapshotStore {
    static let defaultsKey = "SideScreen_nightShiftEyeComfortSnapshots"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: [String: Int]] {
        get { defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Int]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    var isEmpty: Bool { all.isEmpty }

    func snapshot(for serialNumber: String) -> EyeComfortSettings? {
        all[serialNumber].flatMap(EyeComfortSettings.init(dictionary:))
    }

    func save(_ settings: EyeComfortSettings, for serialNumber: String) {
        var all = self.all
        all[serialNumber] = settings.dictionary
        self.all = all
    }

    func remove(_ serialNumber: String) {
        var all = self.all
        all.removeValue(forKey: serialNumber)
        self.all = all
    }
}

/// Mirrors the Mac's Night Shift into the tablet's native Eye comfort shield
/// over adb. Samsung keeps `blue_light_filter*` outside the public settings
/// table, so the Android app's own write is refused ("You cannot change
/// private secure settings") even with WRITE_SECURE_SETTINGS. The adb shell
/// identity is the one path that works, over USB or wireless adb.
///
/// Only devices with SideTab installed and Samsung's keys present are
/// touched. All adb work runs on one serial queue, and only the newest
/// request is kept, so dragging the Mac slider never stacks subprocesses.
final class NightShiftTabletFilter {
    typealias Shell = (_ serial: String, _ script: String) -> String?

    private enum Command {
        case show(NightShiftTarget)
        case release
    }

    private let listDevices: () -> String?
    private let shell: Shell
    private let snapshots: EyeComfortSnapshotStore
    private let pause: (TimeInterval) -> Void
    private let queue = DispatchQueue(label: "NightShiftTabletFilter", qos: .utility)
    private let lock = NSLock()
    private var pending: Command?
    private var drainScheduled = false
    private var lastSkipReason: String?

    /// Long enough for BlueLightFilterService's observer to act on the
    /// "off" write before the schedule keys change underneath it.
    static let restorePause: TimeInterval = 0.5

    init(
        listDevices: @escaping () -> String? = NightShiftTabletFilter.adbDevices,
        shell: @escaping Shell = NightShiftTabletFilter.adbShell,
        snapshots: EyeComfortSnapshotStore = EyeComfortSnapshotStore(),
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.listDevices = listDevices
        self.shell = shell
        self.snapshots = snapshots
        self.pause = pause
    }

    /// Show `target` on every eligible tablet. An `enabled=false` target
    /// hands each tablet back to its own settings.
    func show(_ target: NightShiftTarget) {
        submit(target.enabled ? .show(target) : .release)
    }

    /// Hand every tablet back to its own Eye comfort settings.
    func release() {
        submit(.release)
    }

    /// True while some tablet still carries the mirror's override, for
    /// example because it was unplugged before the release could reach it.
    var hasPendingRestores: Bool {
        !snapshots.isEmpty
    }

    /// Block until work submitted before this call has finished, for app
    /// termination and tests. Returns false on timeout.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func submit(_ command: Command) {
        lock.lock()
        pending = command
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { self.drain() } }
    }

    private func drain() {
        lock.lock()
        let command = pending
        pending = nil
        drainScheduled = false
        lock.unlock()
        if let command { run(command) }
    }

    private func run(_ command: Command) {
        // Nothing saved means nothing to restore: skip the adb round trips.
        if case .release = command, snapshots.isEmpty { return }
        for (serial, probe) in eligibleTablets() {
            switch command {
            case .show(let target):
                show(target, on: serial, probe: probe)
            case .release:
                restore(serial, probe: probe)
            }
        }
    }

    private func eligibleTablets() -> [(serial: String, probe: EyeComfortPlan.Probe)] {
        guard let output = listDevices() else {
            noteSkip("adb unavailable")
            return []
        }
        var seen = Set<String>()
        var tablets: [(String, EyeComfortPlan.Probe)] = []
        for serial in EyeComfortPlan.readySerials(fromDevicesOutput: output) {
            guard let raw = shell(serial, EyeComfortPlan.probeScript),
                  let probe = EyeComfortPlan.parseProbe(raw),
                  probe.hasSideTab, probe.settings != nil,
                  seen.insert(probe.serialNumber).inserted
            else { continue }
            tablets.append((serial, probe))
        }
        if tablets.isEmpty { noteSkip("no adb tablet with SideTab and Eye comfort shield") }
        return tablets
    }

    private func show(_ target: NightShiftTarget, on serial: String, probe: EyeComfortPlan.Probe) {
        guard let current = probe.settings else { return }
        if snapshots.snapshot(for: probe.serialNumber) == nil {
            snapshots.save(current, for: probe.serialNumber)
            debugLog("NightShift -> \(serial): saved tablet Eye comfort \(current.dictionary)")
        }
        let writes = EyeComfortPlan.writes(toShow: target.level, over: current)
        guard !writes.isEmpty else { return }
        if shell(serial, EyeComfortPlan.script(for: writes)) != nil {
            lastSkipReason = nil
            debugLog("NightShift -> \(serial): Eye comfort level \(target.level)/\(NightShiftTarget.maximumLevel)")
        } else {
            debugLog("NightShift -> \(serial): settings write failed")
        }
    }

    private func restore(_ serial: String, probe: EyeComfortPlan.Probe) {
        guard let current = probe.settings,
              let saved = snapshots.snapshot(for: probe.serialNumber) else { return }
        let phases = EyeComfortPlan.restorePhases(from: current, to: saved)
        if !phases.off.isEmpty {
            guard shell(serial, EyeComfortPlan.script(for: phases.off)) != nil else {
                debugLog("NightShift -> \(serial): restore failed, keeping saved settings")
                return
            }
            pause(Self.restorePause)
        }
        if !phases.restore.isEmpty,
           shell(serial, EyeComfortPlan.script(for: phases.restore)) == nil {
            debugLog("NightShift -> \(serial): restore failed, keeping saved settings")
            return
        }
        snapshots.remove(probe.serialNumber)
        debugLog("NightShift -> \(serial): restored tablet Eye comfort \(saved.dictionary)")
    }

    private func noteSkip(_ reason: String) {
        guard reason != lastSkipReason else { return }
        lastSkipReason = reason
        debugLog("NightShift: tablet filter skipped (\(reason))")
    }

    // MARK: - adb

    static func adbDevices() -> String? {
        guard let adb = StatusDetector.adbExecutablePath(),
              let result = ADBCommandRunner.run(adb, arguments: ["devices", "-l"]),
              result.succeeded else { return nil }
        return result.output
    }

    static func adbShell(serial: String, script: String) -> String? {
        guard let adb = StatusDetector.adbExecutablePath(),
              let result = ADBCommandRunner.run(adb, arguments: ["-s", serial, "shell", script]),
              result.succeeded else { return nil }
        return result.output
    }
}
