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
    /// Samsung logs this exact line from the type-25 `onStartCommand` path.
    /// Counting it before/after the queued start is the only observed way adb
    /// can distinguish execution from mere delivery; `am startservice` itself
    /// returns after queueing.
    static let serviceOffLogNeedle = "FILTER_OFF (Setting)"
    static let serviceOffLogCountScript =
        "logcat -d -s BlueLightFilterService:I 2>/dev/null | grep -c '\(serviceOffLogNeedle)' 2>/dev/null; true"

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
    ///
    /// The deterministic Custom/scheduled keys are required here too, not
    /// only on the warm path: Samsung's type-25 handler is a no-op when it
    /// reads `scheduled=0`, which is exactly the state of an Adaptive or
    /// unscheduled tablet when the first host sample is Mac-off.
    static func offScript(over current: EyeComfortSettings) -> String {
        script(for: writes(toTurnOffOver: current), then: serviceScript(serviceOff))
    }

    static func writes(toTurnOffOver current: EyeComfortSettings) -> [Write] {
        var out: [Write] = []
        // Filter first gives a running service the earliest chance to drop
        // the panel; the following mode writes make the queued type-25 intent
        // valid even when that observer is not running.
        if current.filter != 0 { out.append(Write(key: keyFilter, value: 0)) }
        if let adaptive = current.adaptive, adaptive != 0 {
            out.append(Write(key: keyAdaptive, value: 0))
        }
        if current.type != typeAlwaysOn { out.append(Write(key: keyType, value: typeAlwaysOn)) }
        if current.scheduled != 1 { out.append(Write(key: keyScheduled, value: 1)) }
        return out
    }

    /// The restore phases as shell scripts. Phase one always runs — even
    /// when the probed filter key is already 0 — because `am startservice`
    /// only queues work. An earlier apply/off intent can otherwise execute
    /// after the user's schedule keys have been restored and become a no-op,
    /// leaving the panel in the mirror's last visual state. The caller must
    /// confirm execution of this off intent before sending phase two.
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
        // that key. The first override migrates them explicitly; this fallback
        // also covers a stranded pre-migration snapshot because the old mirror
        // never rewrote Adaptive, so the probed live value is still the user's.
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
    /// (`model:SM_X800`) is retained as a sanity check for wireless clients,
    /// whose stronger scoping signal is the authenticated peer IP compared
    /// with a wireless adb `IP:port` serial.
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

    /// Lowercase IP literal text, without brackets or an interface zone. This
    /// is intentionally not hostname resolution: a name cannot prove that an
    /// adb transport is the already-authenticated streaming peer.
    static func normalizedHost(_ value: String?) -> String? {
        guard var host = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { return nil }
            host = String(host[host.index(after: host.startIndex)..<end])
        }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        return host.isEmpty ? nil : host
    }

    /// Host portion of an adb wireless serial. IPv4 serials are `host:port`;
    /// bracketed IPv6 serials are `[host]:port`. Hardware USB serials and
    /// unbracketed IPv6 return nil rather than guessing at colons.
    static func adbSerialHost(_ serial: String) -> String? {
        if serial.hasPrefix("[") {
            guard let end = serial.firstIndex(of: "]") else { return nil }
            return normalizedHost(String(serial[serial.index(after: serial.startIndex)..<end]))
        }
        guard let colon = serial.lastIndex(of: ":") else { return nil }
        let host = String(serial[..<colon])
        // IPv4/hostname serials contain exactly one colon. Anything with an
        // earlier colon is unbracketed IPv6 or another adb form we cannot
        // correlate safely.
        guard !host.contains(":") else { return nil }
        return normalizedHost(host)
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

    var serialNumbers: [String] { Array(all.keys) }

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
    /// the host through adb reverse; the client is the single adb transport
    /// carrying both reverse mappings for the active video/control ports.
    /// Wireless streaming must correlate the authenticated peer IP with a
    /// wireless adb IP:port serial and also match the client model. Once
    /// identified, the hardware serial is bound for the life of that client
    /// connection so a later hotplug cannot be substituted for it.
    enum ClientScope: Equatable {
        case usb(videoPort: Int, controlPort: Int)
        case wireless(deviceModel: String, clientHost: String)
    }

    private enum Command {
        case show(NightShiftTarget)
        case off
        case releaseAll
        case releaseDisconnectedClient
    }

    private struct ClientIdentity {
        let transportSerial: String
        let probe: EyeComfortPlan.Probe

        var hardwareSerial: String { probe.serialNumber }
    }

    private let listDevices: () -> String?
    private let reverseList: (String) -> String?
    private let shell: Shell
    private let snapshots: EyeComfortSnapshotStore
    private let pause: (TimeInterval) -> Void
    private let queue = DispatchQueue(label: "NightShiftTabletFilter", qos: .utility)
    private let lock = NSLock()
    private var pending: Command?
    private var drainScheduled = false
    private var lastSkipReason: String?
    private var clientScope: ClientScope?
    private var boundClientHardwareSerial: String?
    private var reconciliationNeeded = false

    /// Poll Samsung's own execution log briefly after queueing type 25. This
    /// is bounded, but failure is fail-safe: the user's keys are not rewritten
    /// and the snapshot remains pending for the existing release retry.
    static let restoreOffPollInterval: TimeInterval = 0.1
    static let restoreOffPollAttempts = 30

    init(
        listDevices: @escaping () -> String? = NightShiftTabletFilter.adbDevices,
        reverseList: @escaping (String) -> String? = NightShiftTabletFilter.adbReverseList,
        shell: @escaping Shell = NightShiftTabletFilter.adbShell,
        snapshots: EyeComfortSnapshotStore = EyeComfortSnapshotStore(),
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.listDevices = listDevices
        self.reverseList = reverseList
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
        // Every connect event is a new endpoint identity proof. Clear the old
        // binding so the first command can identify this client; until then a
        // hotplugged lookalike cannot inherit the previous client's ownership.
        boundClientHardwareSerial = nil
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
        submit(.releaseAll)
    }

    /// Grace-period release for a disconnect. If the same physical client has
    /// already reconnected and can be identified, its override remains in
    /// place; snapshots for every other device are still handed back. When no
    /// active client scope exists this is equivalent to a full release.
    func releaseDisconnectedClient() {
        submit(.releaseDisconnectedClient)
    }

    /// True while some tablet still carries the mirror's override, for
    /// example because it was unplugged before the release could reach it.
    var hasPendingRestores: Bool {
        !snapshots.isEmpty
    }

    /// True when a saved override belongs to something other than the
    /// currently bound physical client. The active client's own snapshot is
    /// expected while mirroring and must not be treated as a foreign leak.
    var hasPendingRestoresOutsideActiveClient: Bool {
        let bound = boundHardwareSerial()
        return snapshots.serialNumbers.contains { $0 != bound }
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
        if case .releaseAll = command, snapshots.isEmpty { return }
        if case .releaseDisconnectedClient = command, snapshots.isEmpty { return }
        switch command {
        case .show, .off:
            guard let scope = currentClientScope() else {
                noteSkip("no connected client transport identity")
                return
            }
            guard let identity = resolveClientIdentity(scope) else {
                setReconciliationNeeded(true)
                return
            }
            if let bound = boundHardwareSerial(), bound != identity.hardwareSerial {
                // Within one connection the physical answer is not allowed to
                // change. This is the temporal hotplug substitution guard.
                noteSkip("adb device no longer matches the connected client's hardware serial")
                setReconciliationNeeded(true)
                return
            }
            if boundHardwareSerial() == nil {
                // A replacement client does not inherit the session while the
                // prior tablet is still under SideTab control. Attempt its
                // hand-back first; unreachable snapshots remain for the retry.
                restoreSnapshots(except: identity.hardwareSerial)
                setBoundHardwareSerial(identity.hardwareSerial)
            }
            guard identity.probe.hasSideTab, identity.probe.settings != nil else {
                noteSkip("connected client is not a Samsung tablet with SideTab and Eye comfort shield")
                setReconciliationNeeded(true)
                return
            }
            let applied = switch command {
            case .show(let target): show(target, on: identity.transportSerial, probe: identity.probe)
            case .off: turnOff(on: identity.transportSerial, probe: identity.probe)
            case .releaseAll, .releaseDisconnectedClient: true
            }
            setReconciliationNeeded(!applied)
        case .releaseAll:
            // Unconditional stop/quit/startup release: any device with a
            // snapshot has already been mutated and must be handed back even
            // if the current session scope is gone or ambiguous.
            restoreSnapshots(except: nil)
        case .releaseDisconnectedClient:
            // A non-nil scope here means the mirror believes a replacement or
            // reconnected client is active. Identify it now; inability to do
            // so is fail-safe and releases every outstanding snapshot.
            let activeHardware: String?
            if let scope = currentClientScope() {
                // A transient adb/probe failure must not restore the tablet
                // that is actively being mirrored. The durable binding is
                // proof earned earlier in this same connection and is the
                // correct fallback; without any binding, fail closed to a
                // full hand-back.
                activeHardware = resolveClientIdentity(scope)?.hardwareSerial ?? boundHardwareSerial()
            } else {
                activeHardware = nil
            }
            restoreSnapshots(except: activeHardware)
        }
    }

    private func boundHardwareSerial() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return boundClientHardwareSerial
    }

    private func setBoundHardwareSerial(_ value: String?) {
        lock.lock()
        boundClientHardwareSerial = value
        lock.unlock()
    }

    /// Restore every visible snapshot except the active physical client. This
    /// is used both for ownership transfer and conditional grace expiry. A
    /// missing/unreachable device simply keeps its snapshot for the retry.
    private func restoreSnapshots(except activeHardwareSerial: String?) {
        for (serial, probe) in eligibleTabletsForRelease() {
            guard probe.serialNumber != activeHardwareSerial else { continue }
            restore(serial, probe: probe)
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

    /// Resolve the streaming endpoint to one adb transport and hardware
    /// serial. The probe is returned even when Samsung keys are absent: that
    /// still identifies the physical client for safe release decisions, but
    /// the control path separately rejects it as ineligible.
    private func resolveClientIdentity(_ scope: ClientScope) -> ClientIdentity? {
        guard let transports = adbTransports() else { return nil }
        let candidates: [EyeComfortPlan.ReadyTransport]
        let scopeDescription: String
        switch scope {
        case .usb(let videoPort, let controlPort):
            // `adb reverse` is per-device, independent of whether that device
            // uses a physical USB or network adb transport. The active USB-mode
            // stream necessarily traverses both reverse mappings. Stale or
            // manually duplicated mappings make the answer ambiguous and fail
            // closed rather than selecting an idle Samsung device.
            candidates = transports.filter { transport in
                guard let output = reverseList(transport.serial) else { return false }
                return StatusDetector.reverseMappingConfigured(in: output, port: videoPort)
                    && StatusDetector.reverseMappingConfigured(in: output, port: controlPort)
            }
            scopeDescription = "carrying the active adb reverse video/control mappings"
        case .wireless(let deviceModel, let clientHost):
            guard let wantedModel = EyeComfortPlan.normalizedModel(deviceModel),
                  let wantedHost = EyeComfortPlan.normalizedHost(clientHost)
            else {
                noteSkip("wireless client identity is incomplete")
                return nil
            }
            // A wireless stream proves only its peer IP. A USB adb serial is
            // hardware text and cannot be correlated with that peer, so it is
            // deliberately ineligible here. Wireless adb normally uses an
            // IP:port serial; requiring both that exact host and the model is
            // conservative, at the cost of no mirroring for hostname/mDNS adb
            // serials.
            candidates = transports.filter {
                !$0.isUSB
                    && EyeComfortPlan.normalizedModel($0.model) == wantedModel
                    && EyeComfortPlan.adbSerialHost($0.serial) == wantedHost
            }
            scopeDescription = "matching wireless client \(clientHost) model \(deviceModel)"
        }
        guard candidates.count == 1 else {
            noteSkip(candidates.isEmpty
                ? "no adb transport \(scopeDescription)"
                : "multiple adb transports \(scopeDescription); client identity ambiguous")
            return nil
        }
        let transport = candidates[0]
        guard let raw = shell(transport.serial, EyeComfortPlan.probeScript),
              let probe = EyeComfortPlan.parseProbe(raw)
        else {
            noteSkip("could not probe the connected client's adb hardware serial")
            return nil
        }
        return ClientIdentity(transportSerial: transport.serial, probe: probe)
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
        if var saved = snapshots.snapshot(for: serialNumber) {
            // Snapshots written before Adaptive mode was modelled lack the
            // key. The first command under this implementation is also the
            // first point at which Adaptive can be forced off, so the pre-write
            // probe still carries the user's original value. Augment the
            // snapshot before overriding anything; inferring it later from the
            // live keys would read the mirror's own forced zero.
            if saved.adaptive == nil, let adaptive = current.adaptive {
                saved.adaptive = adaptive
                snapshots.save(saved, for: serialNumber)
                debugLog("NightShift -> \(transportSerial): migrated tablet Eye comfort snapshot \(saved.dictionary)")
            }
            return
        }
        snapshots.save(current, for: serialNumber)
        debugLog("NightShift -> \(transportSerial): saved tablet Eye comfort \(current.dictionary)")
    }

    private func restore(_ serial: String, probe: EyeComfortPlan.Probe) {
        guard let current = probe.settings,
              var saved = snapshots.snapshot(for: probe.serialNumber) else { return }
        // Launch/retry release does not pass through saveSnapshotIfNeeded.
        // Capture a legacy snapshot's pre-off Adaptive value now, before phase
        // one necessarily rewrites the live key to zero. The post-off verified
        // state cannot be a migration source.
        if saved.adaptive == nil, let adaptive = current.adaptive {
            saved.adaptive = adaptive
            snapshots.save(saved, for: probe.serialNumber)
            debugLog("NightShift -> \(serial): migrated tablet Eye comfort snapshot \(saved.dictionary)")
        }
        guard let offCountBefore = serviceOffExecutionCount(serial) else {
            debugLog("NightShift -> \(serial): cannot observe Samsung service execution; keeping saved settings")
            return
        }
        let initialScripts = EyeComfortPlan.restoreScripts(from: current, to: saved)
        if let off = initialScripts.off {
            guard shell(serial, off) != nil else {
                debugLog("NightShift -> \(serial): restore failed, keeping saved settings")
                return
            }
        }
        guard waitForServiceOffExecution(serial, countBefore: offCountBefore) else {
            // Do not write the user's scheduled/adaptive keys while the off
            // intent is still unobserved. If it executed late after those
            // writes it could read them as scheduled=0 and become a no-op.
            // Leaving the snapshot in place is safe: the mirror state is still
            // deterministic and the existing release retry can try again.
            debugLog("NightShift -> \(serial): panel-off service execution not confirmed; keeping saved settings")
            return
        }
        // The type-25 log line precedes Samsung's scheduled check, so the
        // count is evidence only because no user keys have been written yet.
        // Re-prove that deterministic state immediately before phase two;
        // otherwise a failed partial write or a user racing Settings could
        // make the observed off intent a no-op.
        guard let verified = verifiedMirrorOffState(serial, expectedSerialNumber: probe.serialNumber) else {
            debugLog("NightShift -> \(serial): mirror off state not verified; keeping saved settings")
            return
        }
        let scripts = EyeComfortPlan.restoreScripts(from: verified, to: saved)
        if let restore = scripts.restore, shell(serial, restore) == nil {
            debugLog("NightShift -> \(serial): restore failed, keeping saved settings")
            return
        }
        snapshots.remove(probe.serialNumber)
        debugLog("NightShift -> \(serial): restored tablet Eye comfort \(saved.dictionary)")
    }

    /// Number of type-25 executions currently visible in logcat, or nil when
    /// the shell/logcat probe is unavailable. The count is a baseline rather
    /// than a log-clearing operation: an increase means a panel-off command
    /// executed while the pre-restore mirror keys were still in place.
    private func serviceOffExecutionCount(_ serial: String) -> Int? {
        guard let output = shell(serial, EyeComfortPlan.serviceOffLogCountScript) else { return nil }
        return output.split(whereSeparator: \.isNewline).last.flatMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private func waitForServiceOffExecution(_ serial: String, countBefore: Int) -> Bool {
        for _ in 0..<Self.restoreOffPollAttempts {
            pause(Self.restoreOffPollInterval)
            if let count = serviceOffExecutionCount(serial), count > countBefore { return true }
        }
        return false
    }

    private func verifiedMirrorOffState(
        _ serial: String,
        expectedSerialNumber: String
    ) -> EyeComfortSettings? {
        guard let raw = shell(serial, EyeComfortPlan.probeScript),
              let probe = EyeComfortPlan.parseProbe(raw),
              probe.serialNumber == expectedSerialNumber,
              let settings = probe.settings,
              settings.filter == 0,
              settings.type == EyeComfortPlan.typeAlwaysOn,
              settings.scheduled == 1,
              (settings.adaptive ?? 0) == 0
        else { return nil }
        return settings
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

    static func adbReverseList(serial: String) -> String? {
        guard let adb = StatusDetector.adbExecutablePath(),
              let result = ADBCommandRunner.run(adb, arguments: ["-s", serial, "reverse", "--list"]),
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
