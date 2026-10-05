import Cocoa
import SwiftUI

// MARK: - Frosted GroupBox Component

struct FrostedGroupBox<Content: View, Trailing: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

extension FrostedGroupBox where Trailing == EmptyView {
    init(title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
        self.trailing = EmptyView()
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    /// Runtime values are observed only by the small sections that render them.
    /// Do not make these `@ObservedObject` here: doing so relays every stream
    /// status/metric update through the entire settings view.
    let runtime: DisplayRuntimeState
    let performance: DisplayPerformanceState
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false
    @State private var headerHovered = false
    @State private var daemonEnabled = false

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with frosted glass
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)

                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .scaleEffect(headerHovered ? 1.05 : 1)
                    .animation(.spring(response: 0.3), value: headerHovered)
                    .onHover { headerHovered = $0 }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SideTab")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Turn your tablet into a second display")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: { showResetConfirmation = true }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background {
                                Circle().fill(.ultraThinMaterial)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Reset settings")
                    .alert("Reset Settings", isPresented: $showResetConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Reset", role: .destructive) {
                            settings.resetToDefaults()
                            if let window = NSApp.windows.first(where: { $0.title == "SideTab" }) {
                                window.center()
                            }
                        }
                    } message: {
                        Text("This will reset all settings to default values.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                // Connection mode picker — pinned, NOT scrollable.
                HStack(spacing: 6) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Button(action: { settings.connectionMode = mode }) {
                            HStack(spacing: 4) {
                                Image(systemName: mode == .usb ? "cable.connector" : "wifi")
                                Text(mode == .usb ? "USB" : "Wireless")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(settings.connectionMode == mode ? Color.accentColor : Color.clear)
                            .foregroundColor(settings.connectionMode == mode ? .white : .primary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Display Configuration
                        FrostedGroupBox(title: "Display Configuration", icon: "display") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Fixed tablet profile. Alternate and custom
                                // resolutions are intentionally not exposed.
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Resolution")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text("1400 × 876")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        Spacer()
                                        Text("HiDPI · 2800 × 1752 physical")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                }

                                // HiDPI (Retina)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("HiDPI (Retina)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text("Fixed at 2× resolution for sharper text.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    Spacer()
                                    Text("On")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }

                                // Rotation
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Rotation")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                                                .frame(width: 80, height: 50)
                                                .scaleEffect(x: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1)
                                                .rotationEffect(.degrees(Double(settings.rotation)))

                                            Text(settings.rotation == 90 || settings.rotation == 270 ? "Portrait" : "Landscape")
                                                .font(.system(size: 8))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 100, height: 80)

                                        VStack(spacing: 6) {
                                            HStack(spacing: 6) {
                                                RotationButton(degrees: 270, label: "270", isSelected: settings.rotation == 270) {
                                                    settings.rotation = 270
                                                }
                                                RotationButton(degrees: 0, label: "0", isSelected: settings.rotation == 0) {
                                                    settings.rotation = 0
                                                }
                                                RotationButton(degrees: 90, label: "90", isSelected: settings.rotation == 90) {
                                                    settings.rotation = 90
                                                }
                                            }
                                            HStack(spacing: 6) {
                                                Spacer()
                                                RotationButton(degrees: 180, label: "180", isSelected: settings.rotation == 180) {
                                                    settings.rotation = 180
                                                }
                                                Spacer()
                                            }
                                        }
                                    }

                                    if settings.rotation == 90 || settings.rotation == 270 {
                                        Text("Display will be in portrait mode")
                                            .font(.system(size: 10))
                                            .foregroundColor(.accentColor)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Flip Horizontally")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                Text("Mirror left and right")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary.opacity(0.7))
                                            }
                                            Spacer()
                                            Toggle("", isOn: $settings.flipHorizontal)
                                                .toggleStyle(.switch)
                                                .controlSize(.mini)
                                        }

                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Flip Vertically")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                Text("Mirror top and bottom")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary.opacity(0.7))
                                            }
                                            Spacer()
                                            Toggle("", isOn: $settings.flipVertical)
                                                .toggleStyle(.switch)
                                                .controlSize(.mini)
                                        }
                                    }
                                    .padding(.top, 4)

                                    HStack {
                                        Spacer()
                                        Button(action: {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.displays?displayArrangement")!)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "rectangle.connected.to.line.below")
                                                Text("Arrange Displays…")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.top, 10)
                                }

                            }
                        }

                        // Refresh Rate (own block)
                        FrostedGroupBox(title: "Refresh Rate", icon: "speedometer") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Frame Rate")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(settings.refreshRate) Hz")
                                        .font(.system(size: 11, weight: .medium))
                                }

                                HStack(spacing: 6) {
                                    ForEach([30, 60, 90, 120], id: \.self) { rate in
                                        BitrateButton(
                                            label: "\(rate)",
                                            value: rate,
                                            currentValue: settings.refreshRate,
                                            disabled: false
                                        ) {
                                            settings.refreshRate = rate
                                        }
                                    }
                                }

                                if settings.refreshRate >= 90 {
                                    Text("High refresh rate for smooth experience")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                }
                            }
                        }

                        // Touch Control
                        FrostedGroupBox(title: "Touch Control", icon: "hand.tap") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enable Touch Input")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Control Mac from tablet touch")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.touchEnabled)
                                        .labelsHidden()
                                }

                                if !settings.touchEnabled {
                                    Text("Touch input is disabled — tablet is display-only")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                        }

                        // Network Settings (port — applies to both modes; listener binds on it)
                        NetworkSettingsSection(settings: settings, runtime: runtime)

                        // Wireless-mode-only: QR + Paired Devices.
                        if settings.connectionMode == .wireless {
                            WirelessSection(settings: settings,
                                            runtime: runtime,
                                            pairedDeviceStore: (NSApp.delegate as? AppDelegate)?.pairedDeviceStore ?? PairedDeviceStore())
                        }

                        // Startup / headless behaviour
                        FrostedGroupBox(title: "Startup", icon: "power") {
                            VStack(alignment: .leading, spacing: 12) {
                                if #available(macOS 13.0, *) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Launch at Login")
                                                .font(.system(size: 12, weight: .medium))
                                            Text("Run SideTab in the background automatically after you log in.")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { daemonEnabled },
                                            set: { newValue in
                                                do {
                                                    if newValue {
                                                        try DaemonManager.shared.enable()
                                                    } else {
                                                        try DaemonManager.shared.disable()
                                                    }
                                                } catch {
                                                    print("Daemon toggle failed: \(error)")
                                                }
                                                daemonEnabled = DaemonManager.shared.isEnabled
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                    Divider()
                                }

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Auto-start streaming on launch")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Start the server automatically when the app opens, so the tablet can connect without touching the Mac.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.autoStartStreamingOnLaunch)
                                        .labelsHidden()
                                }

                                Divider()

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Startup mode")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Which connection mode to start in when auto-starting.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Picker("", selection: $settings.startupMode) {
                                        Text("USB").tag(ConnectionMode.usb)
                                        Text("Wireless").tag(ConnectionMode.wireless)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 150)
                                    .disabled(!settings.autoStartStreamingOnLaunch)
                                }
                            }
                        }
                        .onAppear {
                            if #available(macOS 13.0, *) {
                                daemonEnabled = DaemonManager.shared.isEnabled
                            }
                        }

                        // Gaming Boost
                        FrostedGroupBox(title: "Gaming Boost", icon: settings.gamingBoost ? "bolt.fill" : "bolt") {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enable Gaming Mode")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Optimized for competitive gaming")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $settings.gamingBoost)
                                        .labelsHidden()
                                }

                                if settings.gamingBoost {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("High bitrate (1000 Mbps)")
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("120 Hz refresh rate")
                                                .font(.system(size: 11))
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 10))
                                            Text("Ultra-low latency encoding")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .padding(.leading, 4)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Streaming Settings
                        FrostedGroupBox(title: "Streaming Settings", icon: "antenna.radiowaves.left.and.right") {
                            VStack(alignment: .leading, spacing: 16) {
                                // Bitrate
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Bitrate")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(settings.effectiveBitrate) Mbps")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.accentColor)
                                    }

                                    HStack(spacing: 6) {
                                        BitrateButton(label: "100", value: 100, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 100
                                        }
                                        BitrateButton(label: "300", value: 300, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 300
                                        }
                                        BitrateButton(label: "500", value: 500, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 500
                                        }
                                        BitrateButton(label: "1000", value: 1000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 1000
                                        }
                                        BitrateButton(label: "2000", value: 2000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                            settings.bitrate = 2000
                                        }
                                    }

                                    HStack(spacing: 8) {
                                        Text("20")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        Slider(value: Binding(
                                            get: { Double(settings.bitrate) },
                                            set: { settings.bitrate = Int($0) }
                                        ), in: 20...5000, step: 10)
                                        .disabled(settings.gamingBoost)
                                        Text("5000")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }

                                    if settings.gamingBoost {
                                        HStack(spacing: 4) {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 10))
                                            Text("Locked at 1000 Mbps in Gaming Boost")
                                                .font(.system(size: 10))
                                        }
                                        .foregroundColor(.orange)
                                    }
                                }

                                // Quality
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Quality Preset")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    Picker("", selection: $settings.quality) {
                                        Text("Ultra Low").tag("ultralow")
                                        Text("Low").tag("low")
                                        Text("Medium").tag("medium")
                                        Text("High").tag("high")
                                        // EXP-FORK: Ultra ladder (quality campaign)
                                        Text("Extra High").tag("extrahigh")
                                        Text("Max").tag("max")
                                        Text("Ultra").tag("ultra")
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(settings.gamingBoost)

                                    if settings.gamingBoost {
                                        Text("Quality locked to Ultra Low in Gaming Boost mode")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    } else if settings.quality == "ultralow" {
                                        Text("Fastest encoding, lowest latency")
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }

                        RuntimeStatusSection(settings: settings, runtime: runtime)
                        PerformanceSection(runtime: runtime, performance: performance)
                    }
                    .padding(20)
                }

                SettingsFooter(settings: settings, runtime: runtime, onRestart: restartApp)
            }
        }
        .frame(width: 480, height: 780)
    }

    /// Restart the app by launching a new instance and terminating current one
    private func restartApp() {
        // Get the app bundle path
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("❌ Could not get app path")
            return
        }

        // Use Process to launch a new instance after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current app
            NSApp.terminate(nil)
        } catch {
            print("❌ Failed to restart: \(error)")
        }
    }
}

// MARK: - Supporting Views

/// A small child view keeps live port/server state out of the root settings
/// layout while preserving immediate control updates.
private struct NetworkSettingsSection: View {
    @ObservedObject var settings: DisplaySettings
    @ObservedObject var runtime: DisplayRuntimeState

    var body: some View {
        FrostedGroupBox(title: "Network Settings", icon: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Server Port")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("Port", value: $settings.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(runtime.isRunning)
                }

                if runtime.isRunning {
                    Text("Stop server to change port")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                } else if settings.connectionMode == .wireless {
                    Text("Changing the port invalidates existing pairings — re-scan the QR on each tablet.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if settings.port != 54321 {
                    Text("Custom port set — Android client must use the same port.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Status rows update independently from the large configuration form.
private struct RuntimeStatusSection: View {
    @ObservedObject var settings: DisplaySettings
    @ObservedObject var runtime: DisplayRuntimeState

    var body: some View {
        FrostedGroupBox(title: "Status", icon: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(title: "Virtual Display",
                          status: runtime.displayCreated ? "Active" : "Inactive",
                          color: runtime.displayCreated ? .green : .secondary,
                          hint: "The macOS virtual display we render into. Created when you click Start; the tablet streams its pixels.")
                StatusRow(title: "Client Connected",
                          status: runtime.clientConnected ? "Yes" : "No",
                          color: runtime.clientConnected ? .green : .secondary,
                          hint: "Whether the Android client app currently has an active stream session.")
                StatusRow(
                    title: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Screen & System Audio" : "Screen Recording",
                    status: runtime.hasScreenRecordingPermission ? "Granted" : "Required",
                    color: runtime.hasScreenRecordingPermission ? .green : .red,
                    hint: "macOS privacy permission required to capture the virtual display. Grant in System Settings → Privacy & Security → Screen Recording."
                )
                StatusRow(title: "Accessibility",
                          status: runtime.hasAccessibilityPermission ? "Granted" : "Optional",
                          color: runtime.hasAccessibilityPermission ? .green : .orange,
                          hint: "Optional permission. Required only if you want touch/tap input from the tablet to control the Mac. Streaming works without it.")
                if runtime.isRunning {
                    StatusRow(title: "Capture Method",
                              status: runtime.captureMethod,
                              color: Self.captureMethodColor(runtime.captureMethod),
                              hint: "Which macOS API is currently capturing the virtual display. SCStream is the modern path; CGDisplayStream fallback activates if SCStream fails (e.g. on certain virtual display configs).")
                }

                // Mode-aware contextual rows
                Divider().padding(.vertical, 4)
                if settings.connectionMode == .usb {
                    StatusRow(title: "ADB installed",
                              status: runtime.adbInstalled ? "Installed" : "Missing",
                              color: runtime.adbInstalled ? .green : .red,
                              hint: "USB mode tunnels the TCP stream through the cable using `adb reverse`. The Android SDK platform-tools copy is preferred, then Homebrew, /usr/local/bin, and PATH.")
                    if !runtime.adbInstalled {
                        Text("brew install android-platform-tools")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(6)
                            .background(Color.black.opacity(0.08))
                            .cornerRadius(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    StatusRow(title: "ADB reverse",
                              status: runtime.adbReverseConfigured ? "OK" : "Pending",
                              color: runtime.adbReverseConfigured ? .green : .orange,
                              hint: "Whether `adb reverse tcp:\(settings.port) tcp:\(settings.port)` is currently configured. The Mac app sets this up automatically when you click Start. Goes green within ~2 seconds after the tablet is plugged in and authorized.")
                    StatusRow(title: "USB device",
                              status: runtime.usbDeviceStatus.label,
                              color: runtime.usbDeviceStatus.isConnected ? .green : (runtime.usbDeviceStatus.needsAction ? .orange : .red),
                              hint: runtime.usbDeviceStatus.hint)
                    HStack(spacing: 8) {
                        Button {
                            settings.onRepairUSBBridge?()
                        } label: {
                            Label(
                                runtime.usbRepairInFlight ? "Repairing…" : "Repair USB Bridge",
                                systemImage: "wrench.and.screwdriver"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(runtime.usbRepairInFlight)
                        if !runtime.usbRepairInFlight, let result = runtime.usbRepairResult {
                            Text(result)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    StatusRow(title: "WiFi",
                              status: runtime.wifiConnected ? "Connected" : "Disconnected",
                              color: runtime.wifiConnected ? .green : .red,
                              hint: "Whether the Mac has an active local-network address. This does not prove that the access point allows peer-to-peer TCP or Bonjour; wireless mode still requires the tablet to reach the listening address.")
                    StatusRow(title: "Listening on",
                              status: runtime.listeningAddress.map { LANAddressResolver.endpoint(host: $0, port: settings.port) } ?? "—",
                              color: runtime.listeningAddress != nil ? .green : .secondary,
                              hint: "The QR includes the preferred local address plus compatible fallbacks. If the Mac changes networks, refresh the QR before pairing a new tablet.")
                }

                if !runtime.hasScreenRecordingPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Screen & System Audio Recording Required" : "Screen Recording Required")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                            ? "Required to capture the virtual display. Go to System Settings > Privacy & Security > Screen & System Audio Recording."
                            : "Required to capture the virtual display.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Button(action: {
                                settings.requestScreenRecordingPermission()
                            }) {
                                HStack {
                                    Image(systemName: "record.circle")
                                    Text("Request Access")
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }) {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("Open Settings")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if !runtime.hasAccessibilityPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .foregroundColor(.blue)
                            Text("Enable Touch Control")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text("Control your Mac from your tablet.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open Settings")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(8)
                }
            }
        }
    }

    /// Only two capture methods are ever reported: "SCStream" and
    /// "CGDisplayStream (fallback)". Anything else — the initial
    /// "Initializing…", or a method a future build adds — is an unknown state
    /// and must not be drawn in the success colour.
    static func captureMethodColor(_ method: String) -> Color {
        if method.contains("fallback") { return .orange }
        if method.contains("SCStream") { return .green }
        return .secondary
    }
}

private struct PerformanceSection: View {
    @ObservedObject var runtime: DisplayRuntimeState
    @ObservedObject var performance: DisplayPerformanceState

    @ViewBuilder
    var body: some View {
        if runtime.clientConnected {
            FrostedGroupBox(title: "Performance", icon: "speedometer") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("FPS")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", performance.currentFPS))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Bitrate")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f Mbps", performance.currentBitrate))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }
}

private struct SettingsFooter: View {
    @ObservedObject var settings: DisplaySettings
    @ObservedObject var runtime: DisplayRuntimeState
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        settings.toggleServer()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: runtime.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 12))
                        Text(runtime.isRunning ? "Stop" : "Start")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(runtime.isRunning ? .red : .accentColor)
                .controlSize(.large)
                .disabled(!runtime.hasScreenRecordingPermission)

                if runtime.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Circle()
                                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
                                    .scaleEffect(1.5)
                            }
                        Text("Running on port \(settings.port)")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                // Restart button
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(.ultraThinMaterial)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .help("Restart App")

                // Quit button
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(.ultraThinMaterial)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .help("Quit SideTab (⌘Q)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
    }
}

struct StatusRow: View {
    let title: String
    let status: String
    let color: Color
    var hint: String?
    @State private var showHint = false
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            if let hint = hint {
                Button(action: { showHint.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(hovering ? .accentColor : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(hint)
                .popover(isPresented: $showHint, arrowEdge: .top) {
                    Text(hint)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(12)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(color)
            }
        }
    }
}

struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                    }
                }
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }
}

struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: degrees == 90 || degrees == 270 ? 16 : 24, height: degrees == 90 || degrees == 270 ? 24 : 16)

                Text("\(label)")
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 50, height: 40)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Settings

class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "SideScreen_"

    // Defaults, in one place. The refresh rate is 60 because that is balanced for
    // most tablets; 120 may saturate high-res panel pipelines, so it is a
    // deliberate choice rather than "the highest FPS available".
    static let defaultPort: UInt16 = 54321  // was 8888 in <=0.7.1; 8888 collides with jupyter/splunk/HP printers
    static let defaultRefreshRate = 60
    static let defaultBitrate = 1000
    static let defaultQuality = "ultralow"  // fastest encoding

    /// The domain the settings panel can actually represent. Persisted values are
    /// user-writable through `defaults`, so anything outside these is a state
    /// the backend has no handling for: a bound value outside its own control's
    /// domain, a rotation with no matching button, or a value the encoder clamps
    /// differently from the label above it.
    static let portRange: ClosedRange<UInt16> = 1...UInt16.max
    static let bitrateRange: ClosedRange<Int> = 20...5000
    static let refreshRateChoices = [30, 60, 90, 120]
    static let rotationChoices = [0, 90, 180, 270]

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet {
            normalised("refreshRate", refreshRate, Self.sanitizedRefreshRate(refreshRate)) { refreshRate = $0 }
        }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet {
            normalised("bitrate", bitrate, Self.sanitizedBitrate(bitrate)) { bitrate = $0 }
        }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet {
            let current = Int(port)
            normalised("port", current, Int(Self.sanitizedPort(current))) { port = UInt16($0) }
        }
    }
    @Published var rotation: Int {
        didSet {
            normalised("rotation", rotation, Self.sanitizedRotation(rotation)) { rotation = $0 }
            syncTransform()
        }
    }
    @Published var flipHorizontal: Bool {
        didSet {
            save("flipHorizontal", flipHorizontal)
            syncTransform()
        }
    }
    @Published var flipVertical: Bool {
        didSet {
            save("flipVertical", flipVertical)
            syncTransform()
        }
    }
    @Published var touchEnabled: Bool {
        didSet { save("touchEnabled", touchEnabled) }
    }
    @Published var connectionMode: ConnectionMode {
        didSet { save("connectionMode", connectionMode.rawValue) }
    }
    @Published var autoStartStreamingOnLaunch: Bool {
        didSet { save("autoStartStreamingOnLaunch", autoStartStreamingOnLaunch) }
    }
    @Published var startupMode: ConnectionMode {
        didSet { save("startupMode", startupMode.rawValue) }
    }

    // Runtime state (not persisted) lives in DisplayRuntimeState and
    // DisplayPerformanceState so live status never relays out this form.

    var onToggleServer: (() -> Void)?
    var onRequestScreenRecordingPermission: (() -> Void)?
    var onRepairUSBBridge: (() -> Void)?

    static let fixedResolution = "1400x876"

    init() {
        // This client is paired with the 2800×1752 tablet. Keep the logical
        // profile fixed at 1400×876 HiDPI so stale or accidental preferences
        // cannot create a mismatched virtual display.
        self.resolution = Self.fixedResolution
        self.refreshRate = Self.sanitizedRefreshRate(
            defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? Self.defaultRefreshRate
        )
        self.hiDPI = true
        self.bitrate = Self.sanitizedBitrate(
            defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? Self.defaultBitrate
        )
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? Self.defaultQuality
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        self.port = Self.sanitizedPort(
            defaults.object(forKey: keyPrefix + "port") as? Int ?? Int(Self.defaultPort)
        )
        self.rotation = Self.sanitizedRotation(defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0)
        self.flipHorizontal = defaults.bool(forKey: keyPrefix + "flipHorizontal")
        self.flipVertical = defaults.bool(forKey: keyPrefix + "flipVertical")
        self.touchEnabled = defaults.object(forKey: keyPrefix + "touchEnabled") as? Bool ?? true
        let modeRaw = defaults.string(forKey: keyPrefix + "connectionMode") ?? ConnectionMode.usb.rawValue
        self.connectionMode = ConnectionMode(rawValue: modeRaw) ?? .usb
        self.autoStartStreamingOnLaunch = defaults.object(forKey: keyPrefix + "autoStartStreamingOnLaunch") as? Bool ?? false
        let startupRaw = defaults.string(forKey: keyPrefix + "startupMode") ?? modeRaw
        self.startupMode = ConnectionMode(rawValue: startupRaw) ?? .usb

        defaults.set(Self.fixedResolution, forKey: keyPrefix + "resolution")
        defaults.set(true, forKey: keyPrefix + "hiDPI")
        syncTransform()
        print("Loaded fixed settings: \(resolution) @ \(refreshRate)Hz HiDPI, bitrate=\(bitrate), quality=\(quality)")
    }

    /// A corrupt or hand-edited plist must never produce a value the UI cannot
    /// render, and must never trap. `UInt16.init(_: Int)` is the *checked*
    /// conversion and SIGTRAPs above 65535, and this init runs on the main
    /// thread while AppDelegate's properties are still being set up — before any
    /// window, menu bar item, or error can be shown.
    static func sanitizedPort(_ raw: Int) -> UInt16 {
        UInt16(clamping: min(max(raw, Int(portRange.lowerBound)), Int(portRange.upperBound)))
    }

    static func sanitizedBitrate(_ raw: Int) -> Int {
        min(max(raw, bitrateRange.lowerBound), bitrateRange.upperBound)
    }

    /// Snapped to a rate the panel offers. A rate in between would show nothing
    /// selected, which reads as a broken control rather than a stored preference.
    static func sanitizedRefreshRate(_ raw: Int) -> Int {
        nearestChoice(raw, to: refreshRateChoices)
    }

    /// Snapped to a rotation the tablet's transform message understands, using
    /// circular distance: 359° is one degree from 0°, not 89 degrees from 270°.
    static func sanitizedRotation(_ raw: Int) -> Int {
        guard let choice = rotationChoices.min(by: { circularDistance($0, raw) < circularDistance($1, raw) }) else {
            return rotationChoices[0]
        }
        return choice
    }

    private static func circularDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let delta = (((lhs - rhs) % 360) + 360) % 360
        return min(delta, 360 - delta)
    }

    private static func nearestChoice(_ raw: Int, to choices: [Int]) -> Int {
        choices.min { lhs, rhs in
            let lhsDelta = abs(lhs - raw)
            let rhsDelta = abs(rhs - raw)
            return lhsDelta == rhsDelta ? lhs < rhs : lhsDelta < rhsDelta
        } ?? choices[0]
    }

    /// Rotation and flips for readers that cannot be on the main thread.
    /// `@Published` storage is a plain `var`, so three separate reads can pair a
    /// new rotation with a stale flip — or race the write outright.
    var transformSnapshot: DisplayTransformStore.Transform {
        transformStore.snapshot
    }

    private let transformStore = DisplayTransformStore()

    private func syncTransform() {
        transformStore.update(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    /// Latch for the write-back below. Unlike a plain stored property, a
    /// `@Published` one that assigns to itself inside its own `didSet` runs the
    /// observer again, and each pass makes it worse rather than converging — the
    /// recursion never bottoms out. The inner pass must only apply the value.
    private var isNormalising = false

    private func normalised<T: Equatable>(_ key: String, _ value: T, _ sanitised: T, assign: (T) -> Void) {
        guard !isNormalising else { return }
        if value != sanitised {
            isNormalising = true
            assign(sanitised)
            isNormalising = false
        }
        save(key, sanitised)
    }

    var effectiveBitrate: Int {
        return gamingBoost ? 1000 : bitrate
    }

    var effectiveQuality: String {
        return gamingBoost ? "ultralow" : quality
    }

    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    func toggleServer() {
        onToggleServer?()
    }

    func requestScreenRecordingPermission() {
        onRequestScreenRecordingPermission?()
    }

    func resetToDefaults() {
        // `connectionMode` belongs here: the alert promises every setting goes
        // back to its default, and leaving one key out means the stored value
        // and the value in memory disagree after a reset.
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "flipHorizontal", "flipVertical",
                    "touchEnabled", "connectionMode", "autoStartStreamingOnLaunch", "startupMode"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        resolution = Self.fixedResolution
        refreshRate = Self.defaultRefreshRate
        hiDPI = true
        bitrate = Self.defaultBitrate
        quality = Self.defaultQuality
        gamingBoost = false
        port = Self.defaultPort
        rotation = 0
        flipHorizontal = false
        flipVertical = false
        touchEnabled = true
        connectionMode = .usb
        autoStartStreamingOnLaunch = false
        startupMode = .usb

        print("Settings reset to defaults")
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        let rotation = transformSnapshot.rotation
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings,
                     runtime: DisplayRuntimeState,
                     performance: DisplayPerformanceState) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "SideTab"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(
            settings: settings,
            runtime: runtime,
            performance: performance
        ))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}

// MARK: - Wireless Section

struct WirelessSection: View {
    @ObservedObject var settings: DisplaySettings
    @ObservedObject var runtime: DisplayRuntimeState
    let pairedDeviceStore: PairedDeviceStore
    @State private var qrImage: NSImage?
    /// Last payload actually rasterised. A tick that produces the same string
    /// skips the render entirely instead of handing SwiftUI a new image every
    /// five seconds forever.
    @State private var renderedPayload: String?
    /// Why there is no QR, when there is none.
    @State private var qrBlockedReason: String?
    /// Monotonic request id: a slow pass can finish after a newer one, and its
    /// result must not overwrite the current one.
    @State private var qrRequest = 0
    @State private var pairedDevices: [PairedDevice] = []
    @State private var showResetConfirm = false
    /// A token minted while the server was running only becomes the one the
    /// listener accepts after the next Start.
    @State private var tokenResetPending = false
    /// `Host.current()` is a per-session constant, and reading it is main-thread
    /// work by Apple's account, so it is resolved once here rather than per tick.
    @State private var macName: String?
    /// Used to force the relative-time labels to recompute every tick even when
    /// the underlying lastConnected timestamp hasn't changed (e.g. while a
    /// device is disconnected and we still want "5 minutes ago" to count up).
    @State private var nowTick: Date = Date()

    static let qrSize: CGFloat = 180

    var body: some View {
        VStack(spacing: 12) {
            if !runtime.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Click Start at the top to begin listening, then scan the QR.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            if tokenResetPending && runtime.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("New pairing token saved. Stop the server and start it again to put the new QR into effect.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            FrostedGroupBox(title: "Pair Device", icon: "qrcode") {
                VStack(spacing: 8) {
                    if let qr = qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: Self.qrSize, height: Self.qrSize)
                            .padding(8)
                            .background(Color.white)
                            .cornerRadius(8)
                    } else {
                        // A QR encoding an address the tablet cannot reach looks
                        // identical to one that works, so an unusable pairing
                        // payload is not rendered at all — the empty state says
                        // what is wrong instead.
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 22))
                                .foregroundColor(.secondary)
                            Text(qrBlockedReason ?? "Generating QR…")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.qrSize)
                        .padding(8)
                    }
                    if qrImage != nil {
                        Text("Scan this QR from SideTab Android (Wireless tab)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    // Reads the address the status refresh already resolved.
                    // Querying the resolver here would run getifaddrs() plus a
                    // getnameinfo() per address on every objectWillChange —
                    // including the ones a mouse-move over this panel produces.
                    Text(runtime.listeningAddress.map { "Listening: \(LANAddressResolver.endpoint(host: $0, port: settings.port))" } ?? "WiFi disconnected — no LAN address")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            FrostedGroupBox(
                title: "Paired Devices (\(pairedDevices.count))",
                icon: "ipad.and.iphone",
                content: {
                if pairedDevices.isEmpty {
                    Text("No devices paired yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(pairedDevices) { device in
                            let isLive = runtime.currentWirelessDevice == device.name
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.system(size: 12, weight: .medium))
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isLive ? Color.green : Color.secondary)
                                            .frame(width: 6, height: 6)
                                        Text(isLive ? "Connected" : relativeTimeString(from: device.lastConnected, to: nowTick))
                                            .font(.system(size: 10))
                                            .foregroundColor(isLive ? .green : .secondary)
                                    }
                                }
                                Spacer()
                                Button("Forget") {
                                    pairedDeviceStore.forget(id: device.id)
                                    refreshPaired()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                    }
                }
                Button("Reset Token (forget all)") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
                .padding(.top, 6)
            },
            trailing: {
                Button(action: {
                    nowTick = Date()
                    refreshPaired()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh list and timestamps")
            })
        }
        .onAppear {
            if macName == nil {
                // An empty `name=` is not the same as an absent one to the
                // client, so fall back rather than send a blank.
                let host = Host.current().localizedName ?? ""
                macName = host.isEmpty ? "Mac" : host
            }
            refreshQR()
            refreshPaired()
            nowTick = Date()
        }
        // A fresh listener snapshots the Keychain at start, which is the moment
        // a token reset becomes the token in effect.
        .onChange(of: runtime.isRunning) { running in
            if running { tokenResetPending = false }
        }
        // One-parameter onChange(of:perform:) works on macOS 13+. The
        // two-parameter form requires macOS 14 and would block Ventura.
        // Deprecation is a compile-time warning only on Xcode 15+ SDKs.
        .onChange(of: settings.port) { _ in refreshQR() }
        // Default mode, not .common: in the common modes this also fires while
        // the window is being dragged or a menu is being tracked — the two
        // moments a main-thread stall is most visible — and the refresh below
        // is the expensive work.
        .onReceive(Timer.publish(every: 5, on: .main, in: .default).autoconnect()) { now in
            nowTick = now
            // Refresh the address list while the window remains open so a
            // Wi-Fi roam updates both the preferred host and its fallbacks.
            refreshQR()
            refreshPaired()
        }
        .alert("Reset Token?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { resetToken() }
        } message: {
            Text(runtime.isRunning
                 ? "This forgets every paired device and mints a new pairing token. The listener that is running right now keeps accepting the current token, so stop the server and start it again before anyone scans the new QR."
                 : "This will disconnect all paired devices. They will need to scan the new QR to connect again.")
        }
    }

    /// Rebuilds the QR off the main thread and publishes only when the payload
    /// actually changed.
    private func refreshQR() {
        let port = settings.port
        let name = macName ?? "Mac"
        // The running listener owns the token: StreamingServer snapshots it
        // once at start and never re-reads the Keychain, so a QR built from a
        // fresh loadOrCreate() can encode a token that server rejects. Reading
        // its snapshot also means a failed Keychain read cannot silently
        // switch the QR mid-session — `loadOrCreate` mints a replacement on any
        // read failure, and the mint is a ~9 ms synchronous securityd IPC.
        let liveToken = (NSApp.delegate as? AppDelegate)?.streamingServer?.expectedAuthToken
        qrRequest += 1
        let request = qrRequest
        DispatchQueue.global(qos: .userInitiated).async {
            let token = liveToken ?? WirelessAuth.load() ?? WirelessAuth.loadOrCreate()
            let hosts = LANAddressResolver.preferredHosts()
            let payload = hosts.first.flatMap {
                PairingURL.build(
                    host: $0,
                    port: port,
                    token: token,
                    name: name,
                    alternateHosts: Array(hosts.dropFirst())
                )
            }
            // CoreImage work and the raster both belong off the main thread; the
            // NSImage itself is created there too, since it is only a cheap
            // wrapper around the already-rasterised bitmap.
            let raster = payload.flatMap { QRRenderer.renderCGImage(url: $0, size: Self.qrSize) }
            DispatchQueue.main.async {
                guard qrRequest == request else { return }
                guard let payload, let raster else {
                    self.renderedPayload = nil
                    self.qrImage = nil
                    self.qrBlockedReason = payload == nil ? Self.noAddressReason : Self.renderFailedReason
                    return
                }
                guard payload != self.renderedPayload else { return }
                self.renderedPayload = payload
                self.qrImage = NSImage(cgImage: raster, size: NSSize(width: Self.qrSize, height: Self.qrSize))
                self.qrBlockedReason = nil
            }
        }
    }

    private static let noAddressReason = "No LAN address on this Mac. Connect to Wi-Fi or Ethernet, then scan the QR — a pairing code needs an address the tablet can reach."
    private static let renderFailedReason = "Could not render the pairing QR. Try refreshing."

    /// Mints a new token and forgets every paired device.
    private func resetToken() {
        // Nothing is pending when no listener is running: the next start reads
        // the freshly persisted token itself.
        tokenResetPending = runtime.isRunning
        DispatchQueue.global(qos: .userInitiated).async {
            // SecItemDelete + SecItemAdd is one synchronous securityd round trip
            // that measured ~9 ms on the main thread — 56% of a 60 Hz frame.
            _ = WirelessAuth.reset()
            DispatchQueue.main.async {
                pairedDeviceStore.clear()
                // The running listener holds a snapshot taken at start, so a
                // freshly minted token would be rejected. Push the new token
                // into it, or the alert's promise to re-scan is a lie.
                (NSApp.delegate as? AppDelegate)?.adoptPairingToken(WirelessAuth.loadOrCreate())
                tokenResetPending = false
                // Re-derives from the listener's snapshot while a server is
                // running, so the QR on screen never advertises a token the
                // running listener would reject.
                refreshQR()
                refreshPaired()
            }
        }
    }

    private func refreshPaired() {
        pairedDevices = pairedDeviceStore.all()
    }

    private func relativeTimeString(from past: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(past))
        if elapsed < 30 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed)) seconds ago" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(elapsed / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
