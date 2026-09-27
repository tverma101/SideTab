import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
@preconcurrency import ScreenCaptureKit

// Debug logging stays callable from latency-sensitive capture/network/input
// paths; all formatting and disk I/O are delegated to the bounded async sink.
func debugLog(_ message: String) {
    AsyncDebugLogger.shared.log(message)
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 20
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
}

private extension Float {
    var clampedUnit: Float { isFinite ? Swift.min(Swift.max(self, 0), 1) : 0 }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var brightnessMonitor: BrightnessMonitor?
    var nativeBrightness: NativeBrightnessController?
    var idleSleepMonitor: IdleSleepMonitor?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to snapshot the disconnect time and identify the live paired-device row.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var statusRefreshTimer: Timer?
    private var lastBackgroundStatusRefreshNs: UInt64 = 0
    /// Prevent overlapping adb subprocess probes when a device or adb server
    /// is slow to answer. The status UI is best-effort; it must never queue
    /// work faster than the connection backend can finish it. The start time
    /// is kept so a probe that never returns cannot latch the flag forever.
    private var statusRefreshInFlight = false
    private var statusRefreshStartedAt: Date?
    /// A replug can leave adb reverse unavailable for several retry intervals.
    /// Serialize the self-healing repair so status ticks cannot start a second
    /// repair while the first one is still retrying.
    private var adbReverseRepairInFlight = false
    private var adbReverseRepairStartedAt: Date?
    /// Cancellation token for startServer(), which runs on the Swift
    /// cooperative pool while stopServer() runs on the main thread. Also owns
    /// the "already starting" reentrancy latch.
    private let startGeneration = StartGeneration()
    /// Display transform published for StreamingServer's network queue.
    private let displayTransformStore = DisplayTransformStore()
    private var isStartingServer: Bool { startGeneration.hasInFlightStart }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        nativeBrightness = NativeBrightnessController()
        nativeBrightness?.onBrightness = { [weak self] level in
            self?.streamingServer?.sendBrightness(level)
        }

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if DaemonManager.shared.isEnabled {
            print("🚀 Launch at Login is enabled - starting silently in background")
            // Do not show settings window automatically.
            // applicationShouldHandleReopen will show it if the user manually launched the app.
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                // CAMPAIGN FORK: forceStart bypass (proven pattern) — skips the
                // permission/SCShareableContent dance so cold starts bind fast
                // (the experiment runner depends on deterministic startup).
                if UserDefaults.standard.bool(forKey: "SideScreen_forceStart") {
                    debugLog("FORCE-START active — bypassing permission checks entirely")
                    await self.startServer()
                } else {
                    await self.checkPermissions()
                    if self.settings.hasScreenRecordingPermission {
                        await self.startServer()
                    } else {
                        debugLog("Auto-start skipped: Screen Recording permission not granted")
                    }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    @MainActor
    private func refreshStatusIndicators() {
        let settingsVisible = settingsWindow?.window?.isVisible == true
        guard settingsVisible || settings.isRunning else { return }

        // A hidden, disconnected service still checks for a replug so it can
        // repair adb reverse, but it does not need the visible checklist's
        // two-second cadence. Skip completed live sessions entirely; the
        // disconnect callback re-enables the background probe on the next tick.
        if !settingsVisible {
            if settings.clientConnected { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if lastBackgroundStatusRefreshNs > 0,
               now >= lastBackgroundStatusRefreshNs,
               now - lastBackgroundStatusRefreshNs < 10_000_000_000 {
                return
            }
            lastBackgroundStatusRefreshNs = now
        }

        // Keep the inline permission state current after the user returns from
        // System Settings, without generating another native prompt.
        settings.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

        // LANAddressResolver already does the interface walk needed by both
        // wireless status fields. Resolve once instead of running getifaddrs()
        // twice every two seconds.
        let lanAddress = LANAddressResolver.primaryHost()
        settings.wifiConnected = lanAddress != nil
        settings.listeningAddress = lanAddress

        // Wireless streaming never needs ADB. Avoid spawning the detached USB
        // checklist task (and avoid PATH/which work in adbInstalled) on every
        // wireless status tick. The paired-device UI already renders a live
        // device as "Connected"; its final lastConnected timestamp is persisted
        // by the disconnect handler, so there is no reason to rewrite JSON /
        // UserDefaults every two seconds while a session is active.
        guard settings.connectionMode == .usb else {
            settings.adbInstalled = false
            settings.usbDeviceConnected = false
            settings.usbDeviceStatus = .notDetected
            settings.adbReverseConfigured = false
            return
        }

        // Once the loopback stream is live, it is already proof that the
        // selected USB reverse mapping works. Do not keep spawning adb while
        // the latency-sensitive capture/send path is active. If the cable or
        // reverse socket actually disappears, the Network.framework terminal
        // callback clears clientConnected and the next tick resumes repair.
        if settings.isRunning && settings.clientConnected {
            settings.adbInstalled = true
            settings.usbDeviceConnected = true
            settings.usbDeviceStatus = .connected(serial: nil)
            settings.adbReverseConfigured = true
            return
        }

        let port = Int(settings.port)
        // Same resolver the server uses: reading the override raw built
        // `adb reverse tcp:100000` for a control port the server cannot bind.
        let controlPort = Int(ControlPortResolver.effective(videoPort: settings.port))

        if statusRefreshInFlight,
           !BackgroundProbeWatchdog.isStale(startedAt: statusRefreshStartedAt, now: Date()) {
            return
        }
        if statusRefreshInFlight {
            debugLog("⏱️ USB status watchdog fired — the previous adb probe never returned")
        }
        statusRefreshInFlight = true
        statusRefreshStartedAt = Date()

        Task.detached { [weak self] in
            // All adb/path/process work stays off the main actor. A stuck adb
            // server must not make the settings window or touch path hitch.
            let adbInstalled = StatusDetector.adbInstalled()
            let usbDeviceStatus = StatusDetector.usbDeviceStatus()
            let usbSerial = usbDeviceStatus.readySerial
            let isConnected = usbDeviceStatus.isConnected
            let reverseOK = usbSerial.map { serial in
                StatusDetector.adbReverseConfigured(serial: serial, port: port)
                    && StatusDetector.adbReverseConfigured(serial: serial, port: controlPort)
            } ?? false
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.statusRefreshInFlight = false
                self.statusRefreshStartedAt = nil

                // Ignore a stale USB probe that completed after a mode/port
                // change. The next timer tick will probe the new state.
                guard self.settings.connectionMode == .usb,
                      Int(self.settings.port) == port else { return }

                self.settings.adbInstalled = adbInstalled
                self.settings.usbDeviceStatus = usbDeviceStatus
                self.settings.usbDeviceConnected = usbDeviceStatus.isConnected
                self.settings.adbReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever we are in USB mode with the server running and a
                // device present but adb reverse missing, (re)establish it.
                // Covers replug, adb-server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                // `.connected(serial: nil)` is a valid status, so the serial is
                // bound here instead of force-unwrapped.
                if let serial = usbSerial,
                   self.settings.connectionMode == .usb,
                   isConnected,
                   self.settings.isRunning,
                   !reverseOK {
                    self.scheduleADBReverseRepair(serial: serial)
                }
            }
        }
    }

    @MainActor
    private func scheduleADBReverseRepair(serial: String) {
        if adbReverseRepairInFlight {
            // A wedged adb can never clear this latch by itself, and this latch
            // is the only thing that gates the self-healing repair.
            guard !BackgroundProbeWatchdog.isStale(
                startedAt: adbReverseRepairStartedAt,
                now: Date()
            ) else {
                debugLog("⏱️ USB bridge repair watchdog fired — the previous repair never returned")
                adbReverseRepairInFlight = false
                adbReverseRepairStartedAt = nil
                return
            }
            return
        }
        adbReverseRepairInFlight = true
        adbReverseRepairStartedAt = Date()
        debugLog("🔌 USB bridge missing while running — (re)establishing adb reverse for \(serial)")

        Task { [weak self] in
            guard let self = self else { return }
            await self.setupADBReverse(serial: serial)
            await MainActor.run {
                self.adbReverseRepairInFlight = false
                self.adbReverseRepairStartedAt = nil
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        // A start that is still in flight is not running yet but is about to
        // be: reading settings.isRunning alone silently discarded the mode
        // change while the ~55 s display-creation window was open.
        let wasRunning = settings.isRunning || isStartingServer
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer()
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rotation, flipHorizontal, flipVertical in
                guard let self = self else { return }
                // Published for StreamingServer's network queue, which reads it
                // in onCodecNegotiated and cannot hop to the main actor.
                self.displayTransformStore.update(
                    rotation: rotation,
                    flipHorizontal: flipHorizontal,
                    flipVertical: flipVertical
                )
                guard self.settings.isRunning else { return }
                print("🔄 Display transform changed: \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
                self.streamingServer?.updateDisplayTransform(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "SideTab")
        }

        // Items are rebuilt on every open (menuNeedsUpdate) so the menu always
        // reflects live server/connection state.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Dim the menu bar icon while the server is stopped — at-a-glance
        // state without opening the menu.
        settings.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.appearsDisabled = !running
            }
            .store(in: &cancellables)
    }

    @MainActor
    @objc private func toggleServerFromMenu() {
        if settings.isRunning {
            stopServer()
        } else {
            Task { [weak self] in
                await self?.startServer()
            }
        }
    }

    @objc private func selectUSBMode() {
        guard settings.connectionMode != .usb else { return }
        settings.connectionMode = .usb
    }

    @objc private func selectWirelessMode() {
        guard settings.connectionMode != .wireless else { return }
        settings.connectionMode = .wireless
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            // The `self` binding must not outlive the hop: a `guard let self`
            // in the closure body promotes a strong local and makes
            // AppDelegate → settings → onToggleServer → AppDelegate a cycle
            // that no release can break.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.isRunning {
                    self.stopServer()
                } else {
                    await self.checkPermissions()
                    if self.settings.hasScreenRecordingPermission {
                        await self.startServer()
                    } else {
                        self.showSettings()
                    }
                }
            }
        }

        settings.onRequestScreenRecordingPermission = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.requestScreenRecordingPermission()
            }
        }
    }

    @MainActor
    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            self?.refreshStatusIndicators()
        }
    }

    /// Adopt a freshly minted pairing token on a listener that is already up.
    /// Without this the settings window can only show the new QR after a full
    /// Stop/Start, because the listener snapshots the token at start.
    @MainActor
    func adoptPairingToken(_ token: Data) {
        streamingServer?.expectedAuthToken = token
    }

    /// Refresh permission state without opening a system prompt. Screen capture
    /// permission is granted in System Settings; starting capture while the
    /// native prompt is unresolved makes ScreenCaptureKit fail and can stack a
    /// second app alert over the system dialog.
    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")
        } else {
            debugLog("Screen recording permission not granted yet")
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    /// Request access only after an explicit user action. This keeps launch
    /// non-blocking and, unlike the old force-start path, never starts capture
    /// while macOS is still resolving its native privacy prompt.
    @MainActor
    func requestScreenRecordingPermission() async {
        let coreGraphicsGranted = CGRequestScreenCaptureAccess()
        debugLog("CoreGraphics Screen Recording request completed: \(coreGraphicsGranted ? "granted" : "not granted")")

        if !coreGraphicsGranted {
            do {
                // macOS 26's privacy pane is "Screen & System Audio Recording".
                // A single explicit ScreenCaptureKit discovery request creates
                // that newer TCC entry without constructing the virtual display,
                // server, or capture pipeline.
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                debugLog("ScreenCaptureKit access request completed")
            } catch {
                debugLog("ScreenCaptureKit access request did not grant access: \(error.localizedDescription)")
            }
        }

        settings.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        if !settings.hasScreenRecordingPermission {
            showSettings()
        }
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse(serial requestedSerial: String? = nil) async {
        let port = settings.port
        let controlPort = ControlPortResolver.effective(videoPort: port)
        let ports = [port, controlPort]
        print("🔌 Setting up ADB reverse for ports \(ports)...")
        debugLog(
            "🔌 setupADBReverse() invoked for ports \(ports)" +
                (requestedSerial.map { " on USB serial \($0)" } ?? "") + "..."
        )

        await Task.detached(priority: .utility) {
            guard let finalAdbPath = StatusDetector.adbExecutablePath() else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            let deviceStatus = StatusDetector.usbDeviceStatus()
            let serial = requestedSerial ?? deviceStatus.readySerial
            guard let serial, !serial.isEmpty else {
                print("⚠️  USB ADB unavailable: \(deviceStatus.label) — \(deviceStatus.hint)")
                debugLog("USB ADB unavailable: \(deviceStatus.label)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")
            print("📱 Targeting USB device: \(serial)")

            // Configure both bulk video and the dedicated control channel.
            // Retry each mapping up to 3 times so USB cannot be left in a
            // half-working state after an authorization delay.
            for reversePort in ports {
                var configured = false
                for attempt in 1...3 {
                    let result = ADBCommandRunner.run(
                        finalAdbPath,
                        arguments: ["-s", serial, "reverse", "tcp:\(reversePort)", "tcp:\(reversePort)"]
                    )
                    let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if let result, result.succeeded {
                        print("✅ ADB reverse setup successful for \(serial): tcp:\(reversePort) -> tcp:\(reversePort)")
                        configured = true
                        break
                    }
                    if let result, result.timedOut {
                        print("⚠️  ADB reverse tcp:\(reversePort) attempt \(attempt)/3 timed out: \(output)")
                    } else {
                        print("⚠️  ADB reverse tcp:\(reversePort) attempt \(attempt)/3 failed: \(output)")
                    }

                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }

                if !configured {
                    print("💡 Make sure Android device is connected via USB with debugging enabled")
                    return
                }
            }
        }.value
    }

    /// NOT @MainActor: NSApplicationDelegate carries no NS_SWIFT_MAIN_ACTOR, so
    /// SE-0316 does not infer isolation for this class and the whole function
    /// below runs on the Swift cooperative pool. That is deliberate — the
    /// blocking `createDisplay` retry loop can take ~55 s — so every shared
    /// property is published through MainActor.run and guarded by
    /// `startGeneration` against the main-actor `stopServer()`.
    func startServer() async {
        guard let token = await beginStart() else {
            debugLog("startServer() ignored — already starting or already running")
            return
        }
        let attempt = StartAttempt()
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        debugLog("🚀 startServer() invoked. Screen Recording permission: \(hasScreenCapture)")
        guard hasScreenCapture else {
            debugLog("❌ startServer aborted: Missing Screen Recording permission")
            startGeneration.finish(token)
            await MainActor.run {
                showSettings()
            }
            return
        }

        do {
            let sessionMode = settings.connectionMode
            let sessionFrameRate = WirelessSessionProfile.frameRate(
                for: sessionMode,
                requested: settings.effectiveRefreshRate
            )
            let sessionBitrateCap = WirelessSessionProfile.bitrateCap(for: sessionMode)
            debugLog(
                "Session profile: mode=\(sessionMode.rawValue) " +
                    "frameRate=\(sessionFrameRate)" +
                    (sessionBitrateCap.map { " bitrateCap=\($0)Mbps" } ?? "")
            )

            // Create virtual display and run ADB setup in parallel
            let vdm = VirtualDisplayManager()
            attempt.virtualDisplayManager = vdm
            let size = settings.resolutionSize
            try vdm.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: sessionFrameRate,
                hiDPI: settings.hiDPI,
                name: "SideTab"
            )

            // Disable mirror mode (may fail if already in extend mode)
            do {
                try vdm.disableMirrorMode()
            } catch {
                // Not critical - continue anyway
            }

            await MainActor.run {
                self.virtualDisplayManager = vdm
                settings.displayCreated = true
            }

            // Run ADB setup (USB only) and display init wait in parallel.
            // For wireless mode, skip ADB entirely — the auth handshake gates LAN connections instead.
            await withTaskGroup(of: Void.self) { group in
                if settings.connectionMode == .usb {
                    group.addTask { await self.setupADBReverse() }
                } else {
                    debugLog("Wireless mode: skipping ADB setup")
                }
                group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            }

            // Everything above this point can be waited out by a user who
            // pressed Cmd-Q or switched connection mode. stopServer() bumps the
            // generation, so continuing here would resurrect the display, the
            // server, the capture pipeline and the idle-sleep assertion.
            guard startGeneration.isCurrent(token) else {
                await rollbackStart(token: token, attempt: attempt, reason: "cancelled while the display was being created")
                return
            }

            vdm.restoreDisplayPosition()

            // Verify display is registered in the system
            if !vdm.verifyDisplayRegistered() {
                debugLog("WARNING: Virtual display not found in online display list — capture may fail")
            }

            // Setup capture
            guard let displayID = vdm.displayID else {
                debugLog("❌ startServer aborted: virtual display reported no display ID")
                await rollbackStart(token: token, attempt: attempt, reason: "virtual display reported no display ID")
                return
            }
            let capture = try await ScreenCapture()
            attempt.screenCapture = capture
            await MainActor.run {
                self.screenCapture = capture
            }
            guard startGeneration.isCurrent(token) else {
                await rollbackStart(token: token, attempt: attempt, reason: "cancelled while capture was being set up")
                return
            }
            capture.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in
                    self.settings.captureMethod = method
                }
            }
            try await capture.setupForVirtualDisplay(
                displayID,
                refreshRate: sessionFrameRate,
                frameRateCap: sessionMode == .wireless ? WirelessFreshnessPolicy.targetFrameRate : nil,
                connectionMode: sessionMode
            )
            guard startGeneration.isCurrent(token) else {
                await rollbackStart(token: token, attempt: attempt, reason: "cancelled after capture setup")
                return
            }

            // Setup server. Control channel (out-of-band ping/pong + keyframe
            // requests) runs on its own port: settings.port + 1, overridable
            // via `defaults write com.sidescreen.app SideScreen_controlPort -int N`.
            // The resolver rejects anything a `defaults write` can produce that
            // would trap (UInt16(Int) traps above 65535, port + 1 traps at
            // 65535) or silently disable the control channel.
            let videoPort = settings.port
            let server = StreamingServer(
                port: videoPort,
                controlPort: ControlPortResolver.effective(videoPort: videoPort)
            )
            attempt.streamingServer = server
            server.touchEnabled = await MainActor.run { self.settings.touchEnabled }
            if settings.connectionMode == .wireless {
                server.expectedAuthToken = WirelessAuth.loadOrCreate()
                server.onWirelessClientPaired = { [weak self] deviceName in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            // Provisional size before codec negotiation. onCodecNegotiated below
            // replaces this with the exact encoded dimensions before the config is
            // sent, so Android configures MediaCodec and its render surface for the
            // pixels actually carried by the stream.
            let transform = await MainActor.run { () -> DisplayTransformStore.Transform in
                let current = DisplayTransformStore.Transform(
                    rotation: self.settings.rotation,
                    flipHorizontal: self.settings.flipHorizontal,
                    flipVertical: self.settings.flipVertical
                )
                self.displayTransformStore.update(current)
                return current
            }
            server.setDisplaySize(width: size.width, height: size.height, rotation: transform.rotation, flipHorizontal: transform.flipHorizontal, flipVertical: transform.flipVertical)
            await MainActor.run {
                self.streamingServer = server
            }
            guard startGeneration.isCurrent(token) else {
                await rollbackStart(token: token, attempt: attempt, reason: "cancelled after the server was created")
                return
            }
            // Main-actor hop: these callbacks are invoked from StreamingServer's
            // networkQueue, where releaseStylusIfNeeded() would post a mouse-up
            // for a pen stroke that handleStylus is still driving on the main
            // thread.
            server.onClientConnected = { [weak self, weak capture] in
                Task { @MainActor in
                    // If the no-client idle policy paused capture, resume it at
                    // the connection boundary instead of waiting for the next
                    // monitor tick. The cached replay/keyframe then has a live
                    // pipeline.
                    capture?.resumeFromIdle()
                    capture?.requestKeyframeOrReplayCachedFrame(force: true)
                    // Re-apply the persisted menu-bar value after the Android
                    // client has joined; StreamingServer queues it until BRIGHT
                    // capability negotiation completes.
                    self?.nativeBrightness?.pushCurrent()
                    self?.settings.clientConnected = true
                }
            }
            // Runs synchronously on the server's network queue BEFORE the
            // display config is sent, so the config below carries the right
            // dimensions for the negotiated codec. Nothing here may hop to the
            // main actor: the transform comes from the lock-guarded store
            // instead of `settings`, which the rotation sink writes on main.
            server.onCodecNegotiated = { [weak self, weak capture, weak server] codec in
                guard let self = self, let capture = capture, let server = server else { return }
                capture.negotiate(codec: codec, clientLimit: server.clientDecodeLimits)
                let enc = capture.encodeSize(for: codec)
                let transform = self.displayTransformStore.snapshot
                server.setDisplaySize(width: enc.width, height: enc.height, rotation: transform.rotation, flipHorizontal: transform.flipHorizontal, flipVertical: transform.flipVertical)
            }
            server.onKeyframeRequested = { [weak capture] force in
                capture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            server.onClientDisconnected = { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    // Stylus state is main-confined and this posts a mouse-up:
                    // a disconnect in the middle of an S Pen drag otherwise left
                    // the button logically down until the user clicked again.
                    self.releaseStylusIfNeeded()
                    self.settings.clientConnected = false
                    // Final lastConnected snapshot at the disconnect moment.
                    self.persistWirelessDeviceDisconnect()
                }
            }

            server.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2 in
                self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2)
            }
            server.onStylusEvent = { [weak self] event in
                self?.handleStylus(event)
            }

            server.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    captured?.settings.currentFPS = fps
                    captured?.settings.currentBitrate = mbps
                }
            }

            // Brightness bridge (experiment-gated): translate BetterDisplay's
            // software-brightness intent for this virtual display into BRIGHT
            // commands on the control channel (client applies real backlight).
            if UserDefaults.standard.bool(forKey: "SideScreen_exp_brightness") {
                await MainActor.run {
                    let monitor = BrightnessMonitor()
                    monitor.onBrightness = { [weak server] level in
                        server?.sendBrightness(level)
                    }
                    // start() adds a 3 Hz timer to the main run loop, which is
                    // not thread-safe and does not wake the loop by itself.
                    monitor.start()
                    self.brightnessMonitor = monitor
                    attempt.brightnessMonitor = monitor
                }
                debugLog("Brightness bridge ENABLED (SideScreen_exp_brightness)")
            } else {
                debugLog("Brightness bridge disabled (knob unset)")
            }

            // Idle sleep: when no client is connected for the grace window,
            // pause capture+encode in either transport mode. Resume on client
            // connect and replay the cached frame while SCStream wakes up.
            let idleSleepKey = "SideScreen_exp_idleSleep"
            let idleSleepEnabled = UserDefaults.standard.object(forKey: idleSleepKey) == nil
                || UserDefaults.standard.bool(forKey: idleSleepKey)
            if idleSleepEnabled {
                let secs = UserDefaults.standard.integer(forKey: "SideScreen_exp_idleSleepSecs")
                let grace = secs > 0 ? Double(secs) : 15.0
                let pause: () -> Void = { [weak capture] in capture?.pauseForIdle() }
                let resume: () -> Void = { [weak capture] in
                    capture?.resumeFromIdle()
                    capture?.requestKeyframeOrReplayCachedFrame(force: true)
                }
                await MainActor.run {
                    let monitor = IdleSleepMonitor(
                        isClientConnected: { [weak self] in self?.settings.clientConnected ?? false },
                        pause: pause,
                        resume: resume,
                        graceSecs: grace
                    )
                    monitor.start()
                    self.idleSleepMonitor = monitor
                    attempt.idleSleepMonitor = monitor
                }
                debugLog("Idle-sleep monitor ENABLED (grace \(grace)s, all transports)")
            } else {
                debugLog("Idle-sleep monitor disabled (SideScreen_exp_idleSleep=false)")
            }

            guard startGeneration.isCurrent(token) else {
                await rollbackStart(token: token, attempt: attempt, reason: "cancelled before the session went live")
                return
            }

            server.start(wireless: sessionMode == .wireless)
            capture.startStreaming(
                to: server,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: sessionFrameRate,
                bitrateCapMbps: sessionBitrateCap,
                frameRateCap: sessionMode == .wireless ? WirelessFreshnessPolicy.targetFrameRate : nil,
                connectionMode: sessionMode
            )

            // Commit in one main-actor step: a stop that landed while the
            // session was being wired is detected here instead of publishing
            // isRunning for a pipeline that was just torn down.
            let committed = await MainActor.run { () -> Bool in
                guard self.startGeneration.isCurrent(token) else { return false }
                settings.isRunning = true
                // Release the latch in the same step that publishes isRunning.
                // An unstructured reset task is enqueued after the caller's
                // continuation, and a connection-mode change landing in that
                // window ran stopServer() and was then rejected as "already
                // starting" — leaving the app stopped with no error.
                self.startGeneration.finish(token)
                return true
            }
            guard committed else {
                await rollbackStart(token: token, attempt: attempt, reason: "stopped while the session was going live")
                return
            }

            print("✅ Server started on port \(videoPort)")
        } catch {
            print("❌ Failed to start: \(error)")
            let errorDescription = error.localizedDescription
            let permissionDenied = !CGPreflightScreenCaptureAccess()
                || errorDescription.localizedCaseInsensitiveContains("TCC")
                || errorDescription.localizedCaseInsensitiveContains("declined")
                || errorDescription.localizedCaseInsensitiveContains("not authorized")
            await MainActor.run {
                // A throw after the display was created used to leave the
                // VirtualDisplayManager live and registered, the capture object
                // half-built, and the stale manager's screen-parameters observer
                // still re-arranging display origins.
                self.tearDown(attempt)
                self.startGeneration.finish(token)

                if permissionDenied {
                    // TCC denial belongs in the existing inline permission card.
                    // Do not stack a blocking app alert over macOS's own prompt.
                    settings.hasScreenRecordingPermission = false
                    showSettings()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Start Server"
                    alert.informativeText = errorDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    /// Claim the start latch. Main-actor: the latch and `settings.isRunning`
    /// have to be read together.
    @MainActor
    private func beginStart() -> StartGeneration.Token? {
        guard !isStartingServer, !settings.isRunning else { return nil }
        return startGeneration.begin()
    }

    /// Undo one start attempt and release the latch in a single main-actor
    /// step. A cancelled token is already owned by nobody, so `finish` is a
    /// no-op for it and the rollback cannot release a newer start's latch.
    private func rollbackStart(token: StartGeneration.Token, attempt: StartAttempt, reason: String) async {
        debugLog("⚠️ startServer() rolling back: \(reason)")
        // A newer attempt that has already gone live owns the running state now:
        // this attempt tears down only what it built, and must not report the
        // app as stopped.
        let stillOwnsState = !startGeneration.isSuperseded(token)
        await MainActor.run {
            self.tearDown(attempt, clearingSettings: stillOwnsState)
            self.startGeneration.finish(token)
        }
    }

    /// Idempotent teardown of a single start attempt, on the main actor
    /// (StreamingServer.stop() drains its own queues with `sync` and must never
    /// be called from one of them). An AppDelegate property is only cleared
    /// while it still holds THIS attempt's object, so a late rollback cannot
    /// destroy a session a newer start already published.
    @MainActor
    private func tearDown(_ attempt: StartAttempt, clearingSettings: Bool = true) {
        attempt.idleSleepMonitor?.stop()
        attempt.brightnessMonitor?.stop()
        attempt.screenCapture?.stopStreaming()
        attempt.streamingServer?.stop()
        attempt.virtualDisplayManager?.destroyDisplay()

        if idleSleepMonitor === attempt.idleSleepMonitor { idleSleepMonitor = nil }
        if brightnessMonitor === attempt.brightnessMonitor { brightnessMonitor = nil }
        if screenCapture === attempt.screenCapture { screenCapture = nil }
        if streamingServer === attempt.streamingServer { streamingServer = nil }
        if virtualDisplayManager === attempt.virtualDisplayManager { virtualDisplayManager = nil }

        guard clearingSettings else { return }
        releaseStylusIfNeeded()
        settings.isRunning = false
        settings.displayCreated = false
        settings.clientConnected = false
        settings.currentFPS = 0
        settings.currentBitrate = 0
        persistWirelessDeviceDisconnect()
    }

    /// StreamingServer.stop() does not report onClientDisconnected, so a quit,
    /// a connection-mode switch or a failed start has to take the final
    /// lastConnected snapshot itself.
    @MainActor
    private func persistWirelessDeviceDisconnect() {
        guard let name = currentWirelessDevice else { return }
        pairedDeviceStore.upsert(name: name, lastConnected: Date())
        currentWirelessDevice = nil
        settings.currentWirelessDevice = nil
    }

    /// Main actor: StreamingServer.stop() `sync`s onto networkQueue,
    /// controlQueue, frameQueue and receiveQueue, so it must not be called from
    /// inside one of them, and the run-loop monitors it stops are main-owned.
    @MainActor
    func stopServer() {
        // Cancel an in-flight start (its display-creation window is ~55 s) and
        // free the latch so the next Start click is accepted immediately.
        startGeneration.cancel()
        // Save display position before destroying
        virtualDisplayManager?.saveDisplayPosition()
        tearDown(StartAttempt(
            virtualDisplayManager: virtualDisplayManager,
            screenCapture: screenCapture,
            streamingServer: streamingServer,
            idleSleepMonitor: idleSleepMonitor,
            brightnessMonitor: brightnessMonitor
        ))

        print("⏹️ Server stopped")
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0
    private var handledTouchCount = 0
    private var lastHandledTouchNs: UInt64 = 0
    private var maxHandledTouchGapMs = 0.0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0
    // Direct S Pen stroke state. Pen contact deliberately bypasses the
    // touch gesture classifier so a fast first stroke cannot become a scroll.
    private var stylusIsDown = false

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0) {
        guard settings.touchEnabled, !stylusIsDown else { return }

        let handledAt = DispatchTime.now().uptimeNanoseconds
        if action == 0 {
            handledTouchCount = 0
            lastHandledTouchNs = handledAt
            maxHandledTouchGapMs = 0
        } else if lastHandledTouchNs > 0 {
            let gapMs = Double(handledAt - lastHandledTouchNs) / 1_000_000.0
            maxHandledTouchGapMs = max(maxHandledTouchGapMs, gapMs)
            lastHandledTouchNs = handledAt
        }
        handledTouchCount += 1
        if handledTouchCount % 120 == 0 {
            debugLog(String(format: "TOUCH handled: count=%d maxGap=%.2fms", handledTouchCount, maxHandledTouchGapMs))
            maxHandledTouchGapMs = 0
        }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    // MARK: - S Pen Entry Point

    /// Handle a negotiated Android stylus packet as a direct mouse/tablet
    /// stroke. Generic touch uses a tap/scroll/long-press classifier; using it
    /// for a pen would turn the first quick stroke into a scroll. CoreGraphics
    /// documents mouse pressure as the path for tablet pens mimicking a mouse,
    /// so the pressure value is preserved on every event.
    func handleStylus(_ event: StylusEvent) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - S Pen input ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)
        let point = CGPoint(
            x: bounds.origin.x + CGFloat(event.x.clampedUnit) * bounds.width,
            y: bounds.origin.y + CGFloat(event.y.clampedUnit) * bounds.height
        )

        switch event.action {
        case 0: // Down
            // Finish any touch drag before taking ownership of the pointer.
            if gestureState == .dragging {
                injectMouseUp(at: touchLastPosition)
            }
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle
            stylusIsDown = true
            stylusLastPosition = point
            stylusUsesRightButton = (event.buttonState & Self.stylusSecondaryButtonMask) != 0
            injectStylusMouseDown(at: point, pressure: event.pressure, tilt: event.tilt, orientation: event.orientation)
            debugLog(String(format: "S PEN down x=%.3f y=%.3f pressure=%.3f tilt=%.3f", event.x, event.y, event.pressure, event.tilt))

        case 1: // Move
            if stylusIsDown {
                stylusLastPosition = point
                injectStylusMouseDragged(to: point, pressure: event.pressure, tilt: event.tilt, orientation: event.orientation)
            } else {
                // Recover gracefully if a contact move arrives after the
                // initial packet was lost; moving the cursor does not
                // synthesize a click.
                moveCursor(to: point)
            }

        case 2: // Up/cancel
            if stylusIsDown {
                stylusLastPosition = point
                injectStylusMouseUp(at: point)
                stylusIsDown = false
                stylusUsesRightButton = false
                debugLog("S PEN up")
            }

        case 3: // Hover
            if !stylusIsDown {
                moveCursor(to: point)
            }

        default:
            break
        }
    }

    private var stylusLastPosition: CGPoint = .zero
    private var stylusUsesRightButton = false

    private static let stylusSecondaryButtonMask: UInt32 = 1 << 6 // Android BUTTON_STYLUS_SECONDARY

    /// Main actor: it mutates the stylus fields that handleStylus drives and
    /// posts a mouse-up for the pending stroke.
    @MainActor
    private func releaseStylusIfNeeded() {
        guard stylusIsDown else { return }
        injectStylusMouseUp(at: stylusLastPosition)
        stylusIsDown = false
        stylusUsesRightButton = false
        debugLog("S PEN released during connection/server cleanup")
    }

    private func injectStylusMouseDown(at point: CGPoint, pressure: Float, tilt: Float, orientation: Float) {
        let mouseType: CGEventType = stylusUsesRightButton ? .rightMouseDown : .leftMouseDown
        let button: CGMouseButton = stylusUsesRightButton ? .right : .left
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            applyStylusMetadata(to: event, pressure: pressure, tilt: tilt, orientation: orientation)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectStylusMouseDragged(to point: CGPoint, pressure: Float, tilt: Float, orientation: Float) {
        let mouseType: CGEventType = stylusUsesRightButton ? .rightMouseDragged : .leftMouseDragged
        let button: CGMouseButton = stylusUsesRightButton ? .right : .left
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button) {
            applyStylusMetadata(to: event, pressure: pressure, tilt: tilt, orientation: orientation)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectStylusMouseUp(at point: CGPoint) {
        let mouseType: CGEventType = stylusUsesRightButton ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = stylusUsesRightButton ? .right : .left
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button) {
            applyStylusMetadata(to: event, pressure: 0, tilt: 0, orientation: 0)
            event.post(tap: .cghidEventTap)
        }
    }

    private func applyStylusMetadata(to event: CGEvent, pressure: Float, tilt: Float, orientation: Float) {
        // CoreGraphics documents subtype TabletPoint plus these fields as the
        // supported path for tablet pens that mimic a mouse. Android reports
        // tilt as an angle from perpendicular; project it into the two
        // normalized CoreGraphics tilt axes using the pen orientation.
        event.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint
        let normalizedPressure = pressure.clampedUnit
        event.setDoubleValueField(.mouseEventPressure, value: Double(normalizedPressure))
        event.setDoubleValueField(.tabletEventPointPressure, value: Double(normalizedPressure))

        let normalizedTilt = (tilt / (.pi / 2)).clampedUnit
        let angle = Double(orientation.isFinite ? orientation : 0)
        event.setDoubleValueField(.tabletEventTiltX, value: sin(angle) * Double(normalizedTilt))
        event.setDoubleValueField(.tabletEventTiltY, value: cos(angle) * Double(normalizedTilt))
        event.setDoubleValueField(.tabletEventRotation, value: angle)
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            touchLastPosition = midpoint

        case 1: // Move
            let distanceChange = abs(distance - initialPinchDistance)
            let midDelta = hypot(midpoint.x - touchLastPosition.x, midpoint.y - touchLastPosition.y)

            // Determine mode if not yet decided
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                if distanceChange > GestureThresholds.pinchMinDistance {
                    gestureState = .pinching
                } else if midDelta > GestureThresholds.tapMaxDistance {
                    gestureState = .twoFingerScroll
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                let scaleDelta = distance - lastPinchDistance
                // Cmd + scroll = zoom in most Mac apps
                let zoomAmount = Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // The 2 s checklist timer is scheduled on the main run loop and is not
        // tied to cancellables: left alone it kept firing (and could spawn adb)
        // for the whole termination sequence.
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu bar quick actions

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (not clickable)
        let statusTitle: String
        if settings.isRunning {
            if settings.clientConnected {
                let device = settings.currentWirelessDevice ?? "tablet"
                statusTitle = "🟢 Connected — \(device)"
            } else {
                statusTitle = "🟡 Waiting for tablet on port \(settings.port)"
            }
        } else {
            statusTitle = "⚪️ Server stopped"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Start / Stop
        let toggle = NSMenuItem(
            title: settings.isRunning ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleServerFromMenu),
            keyEquivalent: "t"
        )
        toggle.target = self
        // Always enabled: gating Start on hasScreenRecordingPermission made the
        // item unreachable for a user who had never granted it, and
        // CGRequestScreenCaptureAccess() is only reachable from the settings
        // window. startServer() already handles the not-granted case.
        toggle.isEnabled = true
        menu.addItem(toggle)

        // Connection mode (switching while running restarts the server, same
        // as changing it in the settings window)
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        let usb = NSMenuItem(title: "USB", action: #selector(selectUSBMode), keyEquivalent: "")
        usb.target = self
        usb.state = settings.connectionMode == .usb ? .on : .off
        modeMenu.addItem(usb)
        let wireless = NSMenuItem(title: "Wireless", action: #selector(selectWirelessMode), keyEquivalent: "")
        wireless.target = self
        wireless.state = settings.connectionMode == .wireless ? .on : .off
        modeMenu.addItem(wireless)
        let modeItem = NSMenuItem(title: "Connection Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let brightnessItem = NSMenuItem()
        let brightnessView = BrightnessMenuItemView(
            level: nativeBrightness?.level ?? UInt8(NativeBrightnessController.persistedLevel)
        )
        brightnessView.onChange = { [weak self] level in
            self?.nativeBrightness?.setLevel(level)
        }
        brightnessItem.view = brightnessView
        menu.addItem(brightnessItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "s")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SideTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

// MARK: - Start/stop coordination

/// Cancellation token and reentrancy latch for startServer().
///
/// startServer() runs on the Swift cooperative pool (AppDelegate is not
/// @MainActor-inferred) while stopServer() runs on the main thread, so the two
/// touch the same properties with no scheduler relationship. The generation is
/// captured at the start of an attempt and re-checked after every await;
/// stopServer() bumps it and the in-flight attempt rolls itself back instead of
/// resurrecting the display, server, capture pipeline and idle-sleep assertion.
///
/// `begin`/`finish` are lock-guarded rather than actor-hopped on purpose: the
/// latch has to be released synchronously with the exit path. Resetting it from
/// an unstructured `Task { @MainActor in }` enqueued it after the caller's
/// continuation, and a connection-mode change landing in that window already ran
/// stopServer() — so the restart was rejected as "already starting" and the app
/// was left stopped with no error shown.
final class StartGeneration: @unchecked Sendable {
    struct Token: Equatable {
        let value: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var newestAttempt: UInt64 = 0
    private var inFlight: UInt64?

    var hasInFlightStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight != nil
    }

    /// nil when a start attempt already holds the latch.
    func begin() -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil else { return nil }
        generation &+= 1
        newestAttempt = generation
        inFlight = generation
        return Token(value: generation)
    }

    /// Release the latch, but only for the attempt that still owns it.
    func finish(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        if inFlight == token.value {
            inFlight = nil
        }
    }

    /// stopServer(): every in-flight attempt is stale from here on.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        inFlight = nil
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight == token.value
    }

    /// True once a LATER attempt has claimed the pipeline, so a stale rollback
    /// must not clear the running state that now belongs to that session. Note
    /// that `cancel()` alone does not supersede an attempt: a start that is
    /// merely cancelled still owns the state its own teardown must reset.
    func isSuperseded(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return newestAttempt > token.value
    }
}

/// The pipeline objects one startServer() attempt created.
///
/// They are published into the AppDelegate properties so the touch, menu and
/// brightness paths can see them, but kept per attempt so a cancelled or failed
/// attempt tears down only what it built and never a session a newer start has
/// already published.
final class StartAttempt {
    var virtualDisplayManager: VirtualDisplayManager?
    var screenCapture: ScreenCapture?
    var streamingServer: StreamingServer?
    var idleSleepMonitor: IdleSleepMonitor?
    var brightnessMonitor: BrightnessMonitor?

    init(
        virtualDisplayManager: VirtualDisplayManager? = nil,
        screenCapture: ScreenCapture? = nil,
        streamingServer: StreamingServer? = nil,
        idleSleepMonitor: IdleSleepMonitor? = nil,
        brightnessMonitor: BrightnessMonitor? = nil
    ) {
        self.virtualDisplayManager = virtualDisplayManager
        self.screenCapture = screenCapture
        self.streamingServer = streamingServer
        self.idleSleepMonitor = idleSleepMonitor
        self.brightnessMonitor = brightnessMonitor
    }
}

/// Lock-guarded copy of the display transform for StreamingServer's network
/// queue. `onCodecNegotiated` runs synchronously on that queue immediately
/// before the display config is sent, so it cannot hop to the main actor, and
/// reading the published `settings` transform from there races the rotation sink.
final class DisplayTransformStore: @unchecked Sendable {
    struct Transform: Equatable {
        var rotation = 0
        var flipHorizontal = false
        var flipVertical = false
    }

    private let lock = NSLock()
    private var current = Transform()

    var snapshot: Transform {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func update(_ transform: Transform) {
        lock.lock()
        current = transform
        lock.unlock()
    }

    func update(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) {
        update(Transform(
            rotation: rotation,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical
        ))
    }
}

/// A wedged adb subprocess must not latch a "probe in progress" flag for the
/// life of the process: both the USB checklist and the self-healing reverse
/// repair skip all work while their flag is set, so one hang would disable them
/// permanently. Every flag set by a detached probe records its start time and is
/// force-cleared once this deadline passes.
enum BackgroundProbeWatchdog {
    /// Longest a probe may hold its flag: three sequential adb calls at
    /// ADBCommandRunner.defaultTimeout plus slack.
    static let defaultStaleAfter: TimeInterval = 20

    static func isStale(
        startedAt: Date?,
        now: Date,
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= staleAfter
    }
}
