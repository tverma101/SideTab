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
    /// `blue_light_filter_adaptive_mode`: 1 when Samsung's Adaptive mode owns
    /// the color pipeline. nil means the key is unsupported or was missing in
    /// a snapshot written before this mode was modelled.
    var adaptive: Int?

    var dictionary: [String: Int] {
        var out = ["filter": filter, "level": level, "scheduled": scheduled, "type": type]
        if let adaptive { out["adaptive"] = adaptive }
        return out
    }

    init(filter: Int, level: Int, scheduled: Int, type: Int, adaptive: Int? = nil) {
        self.filter = filter
        self.level = level
        self.scheduled = scheduled
        self.type = type
        self.adaptive = adaptive
    }

    init?(dictionary: [String: Int]) {
        guard let filter = dictionary["filter"], let level = dictionary["level"],
              let scheduled = dictionary["scheduled"], let type = dictionary["type"]
        else { return nil }
        self.init(filter: filter, level: level, scheduled: scheduled, type: type, adaptive: dictionary["adaptive"])
    }
}

/// Pure planning for driving Eye comfort shield with `settings put`.
///
/// Samsung's BlueLightFilterService pushes a level to the panel
/// (`SemMdnieManager.setNightMode(on, level)`) only when "Set schedule" is
/// on; with type 0 that schedule reads "Always on". With `scheduled=0` a
/// level write is stored but never applied, so the mirror owns all four
/// keys while it is active.
///
/// Writing settings is not enough on its own: the service watches them only
/// for 10-60 s after something starts it, then stops itself. Samsung's
/// Settings app starts it with an intent after every change, and so does
/// the mirror (`serviceScript`). Verified on SM-X800 with Settings closed:
/// writes alone did nothing; the type-24 start logged
/// `FILTER_ON (Setting) : Always ON` and `DDI setNightMode : true, index : 9`.
enum EyeComfortPlan {
    struct Write: Equatable {
        let key: String
        let value: Int
    }

    static let keyFilter = "blue_light_filter"
    static let keyLevel = "blue_light_filter_opacity"
    static let keyScheduled = "blue_light_filter_scheduled"
    static let keyType = "blue_light_filter_type"
    static let keyAdaptive = "blue_light_filter_adaptive_mode"
    static let typeAlwaysOn = 0
    static let sideTabPackage = "com.sidescreen.app"

    /// Exported, unprotected service in Samsung's BlueLightFilter.apk.
    static let serviceComponent = "com.samsung.android.bluelightfilter/.BlueLightFilterService"
    /// `BLUE_LIGHT_FILTER_SERVICE_TYPE` values the Settings app sends:
    /// 24 applies the stored mode and level, 25 turns the panel filter off.
    /// Both act only while `blue_light_filter_scheduled` is on.
    static let serviceApply = 24
    static let serviceOff = 25

    static func serviceScript(_ type: Int) -> String {
        "am startservice -n \(serviceComponent) --ei BLUE_LIGHT_FILTER_SERVICE_TYPE \(type) >/dev/null"
    }

    /// Settings writes, then the service start that applies them. The start
    /// runs even when no key changed, because the panel can be off while the
    /// keys already match (Settings closed, service stopped).
    static func showScript(level: Int, over current: EyeComfortSettings) -> String {
        script(for: writes(toShow: level, over: current), then: serviceScript(serviceApply))
    }

    /// Panel off while the mirror remains in control. Unlike a release, this
    /// keeps the mirror's scheduled mode and the saved user snapshot intact:
    /// while a client is connected, the Mac's off state must mean the tablet
    /// is off even if the tablet's own schedule would have been on.
    static func offScript(over current: EyeComfortSettings) -> String {
        let writes = current.filter != 0 ? [Write(key: keyFilter, value: 0)] : []
        return script(for: writes, then: serviceScript(serviceOff))
    }

    /// The restore phases as shell scripts. Phase one always runs — even
    /// when the probed filter key is already 0 — because `am startservice`
    /// only queues work. An earlier apply/off intent can otherwise execute
    /// after the user's schedule keys have been restored and become a no-op,
    /// leaving the panel in the mirror's last visual state. The shell pause
    /// between the two phases gives that queued off intent time to run while
    /// the mirror's deterministic Custom/scheduled state is still present.
    static func restoreScripts(
        from current: EyeComfortSettings,
        to saved: EyeComfortSettings
    ) -> (off: String?, restore: String?) {
        let phases = restorePhases(from: current, to: saved)
        let off = script(for: phases.off, then: serviceScript(serviceOff))
        let effectiveAdaptive = saved.adaptive ?? current.adaptive ?? 0
        // Samsung's type-24 path is the Custom/scheduled path; it is a no-op
        // once scheduled=0 and is not how Adaptive mode is re-armed. Adaptive
        // is instead restored as the final key write below.
        let apply = saved.filter != 0 && saved.scheduled != 0 && effectiveAdaptive == 0
            ? serviceScript(serviceApply) : nil
        let restore = phases.restore.isEmpty && apply == nil
            ? nil : script(for: phases.restore, then: apply)
        return (off, restore)
    }

    /// Writes that make the shield show `level`, in an order where the last
    /// write always triggers an apply: mode keys first, then the level, then
    /// the on/schedule switches. Keys already at their value are skipped, so
    /// a strength-only change is a single level write.
    static func writes(toShow level: Int, over current: EyeComfortSettings) -> [Write] {
        let level = min(max(level, 0), NightShiftTarget.maximumLevel)
        var out: [Write] = []
        if let adaptive = current.adaptive, adaptive != 0 {
            out.append(Write(key: keyAdaptive, value: 0))
        }
        if current.type != typeAlwaysOn { out.append(Write(key: keyType, value: typeAlwaysOn)) }
        if current.level != level { out.append(Write(key: keyLevel, value: level)) }
        if current.filter != 1 { out.append(Write(key: keyFilter, value: 1)) }
        if current.scheduled != 1 { out.append(Write(key: keyScheduled, value: 1)) }
        return out
    }

    /// Restoring takes two phases with a pause between them. Phase one
    /// always writes filter=0 and re-establishes the mirror's deterministic
    /// Custom state before queueing type 25. Rewriting filter even when it
    /// already reads 0 keeps the script shape fixed; more importantly, the
    /// service start is unconditional, so a previously queued warm apply is
    /// always followed by an explicit panel-off intent. Phase two writes the
    /// user's keys back in trigger-safe order: passive level first, schedule
    /// mode, master switch, and Adaptive mode last so Samsung's adaptive
    /// pipeline sees the complete restored state.
    static func restorePhases(
        from current: EyeComfortSettings,
        to saved: EyeComfortSettings
    ) -> (off: [Write], restore: [Write]) {
        var off = [Write(key: keyFilter, value: 0)]
        if let adaptive = current.adaptive, adaptive != 0 {
            off.append(Write(key: keyAdaptive, value: 0))
        }
        if current.type != typeAlwaysOn { off.append(Write(key: keyType, value: typeAlwaysOn)) }
        if current.scheduled != 1 { off.append(Write(key: keyScheduled, value: 1)) }

        // Snapshots written before Adaptive mode was modelled do not contain
        // that key. The old mirror never rewrote it either, so the value still
        // visible in `current` is the user's original mode and is the best
        // migration source. New snapshots carry their own value.
        let effectiveAdaptive = saved.adaptive ?? current.adaptive
        var restore: [Write] = []
        if current.level != saved.level { restore.append(Write(key: keyLevel, value: saved.level)) }
        // Phase one forces type=0 and scheduled=1. Write the user's values
        // whenever they differ from those forced values, not merely when they
        // differed in the pre-off probe.
        if saved.type != typeAlwaysOn { restore.append(Write(key: keyType, value: saved.type)) }
        if saved.scheduled != 1 { restore.append(Write(key: keyScheduled, value: saved.scheduled)) }
        // Phase one always forces the master switch off.
        if saved.filter != 0 { restore.append(Write(key: keyFilter, value: saved.filter)) }
        // Phase one forces Adaptive off when the key exists. Write it last so
        // Samsung's adaptive pipeline is triggered only after filter/schedule
        // have their final user values.
        if let effectiveAdaptive, effectiveAdaptive != 0 {
            restore.append(Write(key: keyAdaptive, value: effectiveAdaptive))
        }
        return (off, restore)
    }

    /// One `adb shell` round trip that reports everything a sync needs, as
    /// labeled lines so stray stderr text cannot shift a field.
    static let probeScript: String = {
        let header = [
            "echo serial=$(getprop ro.serialno)",
            "pm path \(sideTabPackage) >/dev/null 2>&1 && echo sidetab=1 || echo sidetab=0"
        ]
        let keys = [keyFilter, keyLevel, keyScheduled, keyType, keyAdaptive].map { key in
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
            settings = EyeComfortSettings(
                filter: filter,
                level: level,
                scheduled: scheduled,
                type: type,
                adaptive: fields[keyAdaptive].flatMap { Int($0) }
            )
        }
        return Probe(serialNumber: serial, hasSideTab: sideTab == "1", settings: settings)
    }

    /// `&&` so the shell's exit status reports a failure of any step.
    static func script(for writes: [Write], then last: String? = nil) -> String {
        let steps = writes.map { "settings put system \($0.key) \($0.value)" } + (last.map { [$0] } ?? [])
        return steps.joined(separator: " && ")
    }

    struct ReadyTransport: Equatable {
        let serial: String
        let isUSB: Bool
        let model: String?
    }

    /// Ready transports from `adb devices -l`, USB first so a tablet that is
    /// also paired over Wi-Fi is driven through its cable. The model metadata
    /// (`model:SM_X800`) is retained because wireless clients identify
    /// themselves by `Build.MODEL` (`SM-X800`); comparing normalized forms is
    /// the narrowest scoping signal available without a wire-protocol change.
    static func readyTransports(fromDevicesOutput output: String) -> [ReadyTransport] {
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> ReadyTransport? in
            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            let metadata = fields.dropFirst(2)
            let model = metadata.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return ReadyTransport(
                serial: String(fields[0]),
                isUSB: metadata.contains { $0.hasPrefix("usb:") },
                model: model
            )
        }
        return rows.filter(\.isUSB) + rows.filter { !$0.isUSB }
    }

    static func readySerials(fromDevicesOutput output: String) -> [String] {
        readyTransports(fromDevicesOutput: output).map(\.serial)
    }

    /// Samsung prints adb model metadata with underscores while Build.MODEL
    /// uses hyphens/spaces. Compare only letters and digits so those spelling
    /// differences do not weaken the scoping check.
    static func normalizedModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
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

    /// Conservative identity of the streaming client. USB streaming reaches
    /// the host through adb reverse, so exactly one eligible USB adb device is
    /// a safe control target. Wireless clients carry only Build.MODEL today;
    /// require exactly one adb device whose normalized model matches. If the
    /// answer is absent or ambiguous, the mirror touches nothing rather than
    /// mutating an unrelated Samsung device.
    enum ClientScope: Equatable {
        case usb
        case wireless(deviceModel: String)
    }

    private enum Command {
        case show(NightShiftTarget)
        case off
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
    private var clientScope: ClientScope?
    private var reconciliationNeeded = false

    /// `am startservice` returns before the service runs; give it time to
    /// read the mirror's schedule and turn the panel off before phase two
    /// changes those keys.
    static let restorePause: TimeInterval = 1.0

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

    /// Scope control to the streaming client. Passing nil disables control;
    /// release intentionally ignores this scope so any tablet already carrying
    /// a snapshot can still be handed back.
    func setClientScope(_ scope: ClientScope?) {
        lock.lock()
        clientScope = scope
        lock.unlock()
    }

    /// True when the current target could not be applied because adb, the
    /// scoped tablet, or a settings write failed. NightShiftMirror retries it
    /// periodically while the session remains active.
    var needsReconciliation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reconciliationNeeded
    }

    /// Show `target` on the scoped streaming tablet. An `enabled=false`
    /// target turns the tablet panel filter off while keeping the mirror in
    /// control.
    func show(_ target: NightShiftTarget) {
        submit(target.enabled ? .show(target) : .off)
    }

    /// Hand every snapshotted tablet back to its own Eye comfort settings.
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

    private func currentClientScope() -> ClientScope? {
        lock.lock()
        defer { lock.unlock() }
        return clientScope
    }

    private func setReconciliationNeeded(_ value: Bool) {
        lock.lock()
        reconciliationNeeded = value
        lock.unlock()
    }

    private func run(_ command: Command) {
        // Nothing saved means nothing to restore: skip the adb round trips.
        if case .release = command, snapshots.isEmpty { return }
        switch command {
        case .show, .off:
            guard let scope = currentClientScope() else {
                noteSkip("no connected client transport identity")
                return
            }
            let tablets = eligibleTablets(controlScope: scope)
            guard !tablets.isEmpty else {
                setReconciliationNeeded(true)
                return
            }
            var succeeded = true
            for (serial, probe) in tablets {
                let applied = switch command {
                case .show(let target): show(target, on: serial, probe: probe)
                case .off: turnOff(on: serial, probe: probe)
                case .release: true
                }
                succeeded = applied && succeeded
            }
            setReconciliationNeeded(!succeeded)
        case .release:
            // Releases are deliberately broader than control: any device with
            // a snapshot has already been mutated and must be handed back even
            // if the current session scope is gone or ambiguous.
            for (serial, probe) in eligibleTabletsForRelease() {
                restore(serial, probe: probe)
            }
        }
    }

    private func probedTablets(
        _ transports: [EyeComfortPlan.ReadyTransport]
    ) -> [(serial: String, probe: EyeComfortPlan.Probe)] {
        var seen = Set<String>()
        var tablets: [(String, EyeComfortPlan.Probe)] = []
        for transport in transports {
            let serial = transport.serial
            guard let raw = shell(serial, EyeComfortPlan.probeScript),
                  let probe = EyeComfortPlan.parseProbe(raw),
                  probe.hasSideTab, probe.settings != nil,
                  seen.insert(probe.serialNumber).inserted
            else { continue }
            tablets.append((serial, probe))
        }
        return tablets
    }

    private func adbTransports() -> [EyeComfortPlan.ReadyTransport]? {
        guard let output = listDevices() else {
            noteSkip("adb unavailable")
            return nil
        }
        return EyeComfortPlan.readyTransports(fromDevicesOutput: output)
    }

    private func eligibleTablets(
        controlScope scope: ClientScope
    ) -> [(serial: String, probe: EyeComfortPlan.Probe)] {
        guard let transports = adbTransports() else { return [] }
        let candidates: [EyeComfortPlan.ReadyTransport]
        let scopeDescription: String
        switch scope {
        case .usb:
            candidates = transports.filter(\.isUSB)
            scopeDescription = "matching the USB streaming client"
        case .wireless(let deviceModel):
            let wanted = EyeComfortPlan.normalizedModel(deviceModel)
            candidates = transports.filter {
                EyeComfortPlan.normalizedModel($0.model) == wanted
            }
            scopeDescription = "matching wireless model \(deviceModel)"
        }
        let tablets = probedTablets(candidates)
        guard !tablets.isEmpty else {
            noteSkip("no adb tablet \(scopeDescription) with SideTab and Eye comfort shield")
            return []
        }
        guard tablets.count == 1 else {
            noteSkip("multiple adb tablets \(scopeDescription); control disabled for safety")
            return []
        }
        return tablets
    }

    private func eligibleTabletsForRelease() -> [(serial: String, probe: EyeComfortPlan.Probe)] {
        guard let transports = adbTransports() else { return [] }
        let tablets = probedTablets(transports)
        if tablets.isEmpty { noteSkip("no adb tablet with SideTab and Eye comfort shield") }
        return tablets
    }

    private func show(_ target: NightShiftTarget, on serial: String, probe: EyeComfortPlan.Probe) -> Bool {
        guard let current = probe.settings else { return false }
        saveSnapshotIfNeeded(current, serialNumber: probe.serialNumber, transportSerial: serial)
        if shell(serial, EyeComfortPlan.showScript(level: target.level, over: current)) != nil {
            lastSkipReason = nil
            debugLog("NightShift -> \(serial): Eye comfort level \(target.level)/\(NightShiftTarget.maximumLevel)")
            return true
        }
        debugLog("NightShift -> \(serial): settings write failed")
        return false
    }

    private func turnOff(on serial: String, probe: EyeComfortPlan.Probe) -> Bool {
        guard let current = probe.settings else { return false }
        saveSnapshotIfNeeded(current, serialNumber: probe.serialNumber, transportSerial: serial)
        if shell(serial, EyeComfortPlan.offScript(over: current)) != nil {
            lastSkipReason = nil
            debugLog("NightShift -> \(serial): Eye comfort off (Mac Night Shift off)")
            return true
        }
        debugLog("NightShift -> \(serial): settings write failed")
        return false
    }

    private func saveSnapshotIfNeeded(
        _ current: EyeComfortSettings,
        serialNumber: String,
        transportSerial: String
    ) {
        guard snapshots.snapshot(for: serialNumber) == nil else { return }
        snapshots.save(current, for: serialNumber)
        debugLog("NightShift -> \(transportSerial): saved tablet Eye comfort \(current.dictionary)")
    }

    private func restore(_ serial: String, probe: EyeComfortPlan.Probe) {
        guard let current = probe.settings,
              let saved = snapshots.snapshot(for: probe.serialNumber) else { return }
        let scripts = EyeComfortPlan.restoreScripts(from: current, to: saved)
        if let off = scripts.off {
            guard shell(serial, off) != nil else {
                debugLog("NightShift -> \(serial): restore failed, keeping saved settings")
                return
            }
            pause(Self.restorePause)
        }
        if let restore = scripts.restore, shell(serial, restore) == nil {
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
