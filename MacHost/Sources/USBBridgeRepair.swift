import Foundation

/// The manual "Repair USB Bridge" sequence.
///
/// The automatic USB checklist only repairs the reverse mapping when
/// `adb devices -l` still answers. When ADB itself is the broken part — a
/// wedged server, a squatted port 5037, or a crashed `adbd` leaving the
/// server in a bad state — no automatic path ever runs `adb kill-server`,
/// so the checklist spins on "Not detected" forever. This is the explicit
/// recovery for exactly that state.
///
/// `kill-server` stays behind this manual action on purpose: an automatic
/// timer restarting the ADB server could yank the transport out from under
/// other tooling on this Mac (Android Studio, scrcpy, CI runners) that
/// shares the same ADB binary.
enum USBBridgeRepair {
    /// Restart the ADB server and re-probe the transport.
    ///
    /// `adb devices -l` implicitly restarts a stopped server, so the probe
    /// doubles as `start-server`. Every step is bounded by
    /// `ADBCommandRunner.defaultTimeout`, so the sequence cannot wedge forever.
    static func restartServerAndProbe(adbPath: String) -> ADBUSBDeviceStatus {
        _ = ADBCommandRunner.run(adbPath, arguments: ["kill-server"])
        guard let result = ADBCommandRunner.run(adbPath, arguments: ["devices", "-l"]),
              result.succeeded else {
            return .serverUnreachable
        }
        return StatusDetector.usbDeviceStatus(from: result.output)
    }

    /// Honest post-repair status for the checklist. A tablet that is still
    /// unauthorized or offline after a server restart has a *tablet-side*
    /// problem the Mac cannot fix; the message must say so instead of
    /// sending the user in circles.
    static func resultMessage(for status: ADBUSBDeviceStatus) -> String {
        switch status {
        case let .connected(serial):
            return "ADB restarted; \(serial ?? "the tablet") is visible. Re-establishing the reverse tunnel…"
        case .notDetected:
            return "ADB restarted, but no tablet is visible. Replug the cable, check USB debugging on the tablet, then repair again."
        case .serverUnreachable:
            return "Restarting ADB did not help — the ADB server still does not answer. Another process may be squatting port 5037."
        case let .authorizationRequired(serial):
            return "ADB restarted and sees \(serial), but the tablet has not authorized this Mac. Unlock the tablet and tap Allow."
        case let .offline(serial):
            return "ADB restarted, but \(serial) reports offline. Replug the cable and check for a USB debugging prompt on the tablet."
        }
    }
}