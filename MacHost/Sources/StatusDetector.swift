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
        LANAddressResolver.primaryIPv4() != nil
    }

    /// Run `adb devices`, return list of device serials in `device` state.
    /// Wireless mode never needs this subprocess; AppDelegate refreshes status
    /// every two seconds, so avoiding it removes recurring process churn from
    /// the capture/encode workload.
    static func usbDevices() -> [String] {
        guard !wirelessModeActive else { return [] }
        guard let adbPath = adbExecutablePath() else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Heuristic: parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    /// The status refresh asks for video and control ports back-to-back; cache
    /// the command output briefly so those two checks share one adb process.
    static func adbReverseConfigured(port: Int) -> Bool {
        guard !wirelessModeActive else { return false }
        guard let output = reverseListOutput() else { return false }
        return output.contains("tcp:\(port) tcp:\(port)")
    }

    private static var wirelessModeActive: Bool {
        UserDefaults.standard.string(forKey: "SideScreen_connectionMode") == "wireless"
    }

    private static let cacheLock = NSLock()
    private static var cachedReverseList = ""
    private static var lastReverseListCheck: Date = .distantPast
    private static let reverseListCacheSeconds: TimeInterval = 0.75

    private static func reverseListOutput() -> String? {
        cacheLock.lock()
        if Date().timeIntervalSince(lastReverseListCheck) < reverseListCacheSeconds {
            let cached = cachedReverseList
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let adbPath = adbExecutablePath() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["reverse", "--list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        cacheLock.lock()
        cachedReverseList = output
        lastReverseListCheck = Date()
        cacheLock.unlock()
        return output
    }

    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast

    private static func adbExecutablePath() -> String? {
        // Re-resolve every 5 s so install/uninstall is reflected.
        if let cached = cachedAdbPath, Date().timeIntervalSince(lastAdbCacheCheck) < 5.0 {
            return cached
        }
        let candidatePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedAdbPath = path
            lastAdbCacheCheck = Date()
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
                cachedAdbPath = out
                lastAdbCacheCheck = Date()
                return out
            }
        } catch {
            // ignore
        }
        cachedAdbPath = nil
        lastAdbCacheCheck = Date()
        return nil
    }
}
