import Combine

/// Live server/device state is separate from persisted display settings.
///
/// The settings window observes `DisplaySettings` for configuration controls,
/// while the small status subviews observe this object for runtime changes.
/// Keeping the two observation graphs separate prevents a once-per-second
/// streaming metric from invalidating and relaying out the whole settings tree.
final class DisplayRuntimeState: ObservableObject {
    @Published var displayCreated = false
    @Published var clientConnected = false
    /// Device name of the wireless client currently streaming (nil when none).
    /// WirelessSection reads this to show a "Connected" badge on the matching row.
    @Published var currentWirelessDevice: String?
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var adbInstalled = false
    @Published var adbReverseConfigured = false
    @Published var usbDeviceConnected = false
    @Published var usbDeviceStatus: ADBUSBDeviceStatus = .notDetected
    @Published var wifiConnected = false
    @Published var listeningAddress: String?
    @Published var isRunning = false
    @Published var captureMethod: String = "Initializing..."
}

/// High-frequency stream metrics have their own publisher so FPS/bitrate
/// updates invalidate only the small Performance section.
final class DisplayPerformanceState: ObservableObject {
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
}
