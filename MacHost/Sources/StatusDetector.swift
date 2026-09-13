import Foundation

enum StatusDetector {
    static func adbInstalled() -> Bool {
        return adbExecutablePath() != nil
    }

    /// SideScreen wireless is a LAN service and does not require an Internet
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
        guard let adbPath = adbExecutablePath() else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["devices", "-l"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else { return [] }
        return usbSerials(from: output)
    }

    /// Parse `adb devices -l` and keep only ready transports with a `usb:`
    /// descriptor. Wi-Fi ADB serials such as `192.168.1.130:45809` are
    /// intentionally excluded even though their state is also `device`.
    static func usbSerials(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 3, fields[1] == "device" else { return nil }
            guard fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
                return nil
            }
            return String(fields[0])
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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["-s", serial, "reverse", "--list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else { return nil }

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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !out.isEmpty,
               FileManager.default.isExecutableFile(atPath: out) {
                adbPathCacheLock.lock()
                cachedAdbPath = out
                lastAdbCacheCheck = now
                adbPathCacheLock.unlock()
                return out
            }
        } catch {
            // ignore
        }
        adbPathCacheLock.lock()
        cachedAdbPath = nil
        lastAdbCacheCheck = now
        adbPathCacheLock.unlock()
        return nil
    }
}
