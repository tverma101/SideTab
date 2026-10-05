import Foundation

enum ADBUSBDeviceStatus: Equatable {
    case notDetected
    case connected(serial: String?)
    case authorizationRequired(serial: String)
    case offline(serial: String)
    /// ADB is installed but the `adb devices` probe itself failed or timed
    /// out. This is a *Mac-side* failure (wedged ADB server, squatted port
    /// 5037) and must not be reported as a missing tablet.
    case serverUnreachable

    var readySerial: String? {
        guard case let .connected(serial) = self else { return nil }
        return serial
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var needsAction: Bool {
        switch self {
        case .authorizationRequired(_), .offline(_), .serverUnreachable:
            return true
        case .notDetected, .connected(_):
            return false
        }
    }

    var label: String {
        switch self {
        case .notDetected:
            return "Not detected"
        case .connected(_):
            return "Detected"
        case .authorizationRequired:
            return "Authorize tablet"
        case .offline:
            return "Tablet offline"
        case .serverUnreachable:
            return "ADB not responding"
        }
    }

    var hint: String {
        switch self {
        case .notDetected:
            return "No USB device is visible to ADB. Use a data-capable cable, unlock the tablet, and enable USB debugging."
        case .connected(_):
            return "An authorized Android tablet is visible to ADB. SideTab sets up the USB reverse tunnel automatically."
        case let .authorizationRequired(serial):
            return "ADB sees \(serial), but the tablet has not authorized this Mac. Unlock the tablet and tap Allow USB debugging (choose Always allow if offered)."
        case let .offline(serial):
            return "ADB sees \(serial) as offline. Reconnect the cable, unlock the tablet, and check for a USB debugging prompt."
        case .serverUnreachable:
            return "ADB is installed, but the ADB server on this Mac did not answer. Click Repair USB Bridge — it restarts ADB and re-establishes the reverse tunnel. The tablet is not necessarily at fault."
        }
    }
}

enum StatusDetector {
    static func adbInstalled() -> Bool {
        return adbExecutablePath() != nil
    }

    /// SideTab wireless is a LAN service and does not require an Internet
    /// route. Reuse the same interface/address resolver as pairing instead of
    /// constructing a reachability probe to a public IP on every status tick.
    /// This also reports local-only Wi-Fi/Ethernet correctly.
    static func wifiReachable() -> Bool {
        LANAddressResolver.primaryHost() != nil
    }

    /// Run `adb devices -l`, return physical USB serials in `device` state.
    /// ADB exposes Wi-Fi transports in the same `device` state, so checking the
    /// state alone is not sufficient when USB and wireless debugging are both
    /// enabled for the same tablet.
    static func usbDevices() -> [String] {
        guard !wirelessModeActive else { return [] }
        guard let output = adbDevicesOutput() else { return [] }
        return usbSerials(from: output)
    }

    /// Preserve unauthorized/offline states so the Mac UI can tell the user
    /// why USB reverse forwarding cannot be configured. A probe that ran but
    /// got no answer is reported as `.serverUnreachable` instead of being
    /// collapsed into "no device visible": a wedged ADB server and an
    /// unplugged tablet need different fixes.
    static func usbDeviceStatus() -> ADBUSBDeviceStatus {
        guard !wirelessModeActive else { return .notDetected }
        guard let adbPath = adbExecutablePath() else { return .notDetected }
        guard let result = ADBCommandRunner.run(adbPath, arguments: ["devices", "-l"]),
              result.succeeded else { return .serverUnreachable }
        return usbDeviceStatus(from: result.output)
    }

    static func usbDeviceStatus(from output: String) -> ADBUSBDeviceStatus {
        let rows = usbRows(from: output)
        if let ready = rows.first(where: { $0.state == "device" }) {
            return .connected(serial: ready.serial)
        }
        if let unauthorized = rows.first(where: { $0.state == "unauthorized" }) {
            return .authorizationRequired(serial: unauthorized.serial)
        }
        if let offline = rows.first(where: { $0.state == "offline" }) {
            return .offline(serial: offline.serial)
        }
        return .notDetected
    }

    private static func adbDevicesOutput() -> String? {
        guard let adbPath = adbExecutablePath() else { return nil }
        guard let result = ADBCommandRunner.run(adbPath, arguments: ["devices", "-l"]),
              result.succeeded else { return nil }
        return result.output
    }

    /// Parse `adb devices -l` and keep only ready transports with a `usb:`
    /// descriptor. Wi-Fi ADB serials such as `192.168.1.130:45809` are
    /// intentionally excluded even though their state is also `device`.
    static func usbSerials(from output: String) -> [String] {
        usbRows(from: output)
            .filter { $0.state == "device" }
            .map { $0.serial }
    }

    private static func usbRows(from output: String) -> [(serial: String, state: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 3,
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
                return nil
            }
            return (serial: String(fields[0]), state: String(fields[1]))
        }
    }

    /// Parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    static func reverseMappingConfigured(in output: String, port: Int) -> Bool {
        let expected = "tcp:\(port)"
        return output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split { $0 == " " || $0 == "\t" }
            return fields.count >= 3 && fields[1] == expected && fields[2] == expected
        }
    }

    /// Check a reverse mapping on one explicitly selected USB device.
    /// The status refresh asks for video and control ports back-to-back; cache
    /// the command output briefly so those two checks share one adb process.
    static func adbReverseConfigured(serial: String, port: Int) -> Bool {
        guard !wirelessModeActive else { return false }
        guard let output = reverseListOutput(serial: serial) else { return false }
        return reverseMappingConfigured(in: output, port: port)
    }

    private static var wirelessModeActive: Bool {
        UserDefaults.standard.string(forKey: "SideScreen_connectionMode") == "wireless"
    }

    private static let cacheLock = NSLock()
    private static var cachedReverseList = ""
    private static var cachedReverseListSerial: String?
    private static var lastReverseListCheck: Date = .distantPast
    private static let reverseListCacheSeconds: TimeInterval = 0.75

    private static func reverseListOutput(serial: String) -> String? {
        cacheLock.lock()
        if cachedReverseListSerial == serial,
           Date().timeIntervalSince(lastReverseListCheck) < reverseListCacheSeconds {
            let cached = cachedReverseList
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let adbPath = adbExecutablePath() else { return nil }
        guard let result = ADBCommandRunner.run(
            adbPath,
            arguments: ["-s", serial, "reverse", "--list"]
        ), result.succeeded else { return nil }
        let output = result.output

        cacheLock.lock()
        cachedReverseList = output
        cachedReverseListSerial = serial
        lastReverseListCheck = Date()
        cacheLock.unlock()
        return output
    }

    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast
    private static let adbPathCacheLock = NSLock()

    /// Resolve the same preferred ADB binary used by the command-line install
    /// helpers. Android Studio's SDK platform-tools win over an older
    /// Homebrew copy so device discovery, install, and reverse forwarding all
    /// share one ADB server/version.
    static func adbExecutablePath() -> String? {
        // Re-resolve every 5 s so install/uninstall is reflected.
        let now = Date()
        adbPathCacheLock.lock()
        let cached = cachedAdbPath
        let lastCheck = lastAdbCacheCheck
        adbPathCacheLock.unlock()
        if let cached, now.timeIntervalSince(lastCheck) < 5.0 {
            return cached
        }
        var candidatePaths: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["SIDESCREEN_ADB"],
           !explicit.isEmpty {
            candidatePaths.append(explicit)
        }
        candidatePaths += [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            adbPathCacheLock.lock()
            cachedAdbPath = path
            lastAdbCacheCheck = now
            adbPathCacheLock.unlock()
            return path
        }
        // Fallback: ask `which adb` (covers PATH-installed setups).
        if let result = ADBCommandRunner.run(
            "/usr/bin/which",
            arguments: ["adb"],
            timeout: ADBCommandRunner.shortLookupTimeout
        ), result.succeeded {
            let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                adbPathCacheLock.lock()
                cachedAdbPath = out
                lastAdbCacheCheck = now
                adbPathCacheLock.unlock()
                return out
            }
        }
        adbPathCacheLock.lock()
        cachedAdbPath = nil
        lastAdbCacheCheck = now
        adbPathCacheLock.unlock()
        return nil
    }
}

// MARK: - Subprocess runner

/// Bounded `adb` (and `which`) invocation.
///
/// Two traps are avoided here, both of which are reachable with a real adb:
/// the pipe is drained on a separate queue WHILE the child runs (reading only
/// after `waitUntilExit()` deadlocks once the child outgrows the 64 KB pipe
/// buffer), and the wait has a deadline (`waitUntilExit()` has no timeout
/// variant, and adb can block forever — TCP 5037 squatted by another process
/// makes `adb devices` print its header and hang, `adb reverse` blocks on a
/// wedged transport). An adb that never returns used to latch the USB status
/// refresh and the self-healing reverse repair for the life of the process.
enum ADBCommandRunner {
    struct Result {
        let output: String
        let exitCode: Int32
        let timedOut: Bool

        var succeeded: Bool { !timedOut && exitCode == 0 }
    }

    /// Deadline for a real adb call. Long enough for a cold adb-server start on
    /// a busy machine, short enough that the 2 s status tick cannot pile up.
    static let defaultTimeout: TimeInterval = 5
    /// `which` is a local binary lookup: anything slower than this is a wedged
    /// filesystem, not a slow PATH walk.
    static let shortLookupTimeout: TimeInterval = 2
    /// Grace period between SIGTERM and SIGKILL.
    private static let killGrace: TimeInterval = 1
    private static let unreapedExitCode: Int32 = -1

    /// nil when the child could not be spawned at all.
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        let collector = OutputCollector()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.store(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                if exited.wait(timeout: .now() + killGrace) == .timedOut {
                    // Never reaped. `terminationStatus` raises for a process
                    // that has not terminated, so it must not be read here.
                    _ = drained.wait(timeout: .now() + killGrace)
                    return Result(output: text(collector.value()), exitCode: unreapedExitCode, timedOut: true)
                }
            }
        }

        _ = drained.wait(timeout: .now() + killGrace)
        return Result(
            output: text(collector.value()),
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func text(_ data: Data) -> String {
        return String(data: data, encoding: .utf8) ?? ""
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ data: Data) {
            lock.lock()
            self.data = data
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
