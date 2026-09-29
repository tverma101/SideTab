import Foundation
import AppKit
import CoreGraphics
import ObjectiveC
import os
import CGVirtualDisplayBridge

/// Manages virtual display creation and lifecycle using CGVirtualDisplay API
class VirtualDisplayManager {
    /// Vendor ID every SideScreen descriptor registers. Used to tell our own
    /// displays apart from physical screens, including a stale instance left
    /// behind by a previous process.
    static let vendorID: UInt32 = 0xEEEE

    private struct State {
        var display: CGVirtualDisplay?
        var descriptor: CGVirtualDisplayDescriptor?
        var settings: CGVirtualDisplaySettings?
        var observer: NSObjectProtocol?
        var mirroringEnabled = false
        var pointsSize: CGSize = .zero
    }

    /// createDisplay runs on a task-pool thread while the screen-parameters
    /// observer re-arranges on main, so every access to the display's lifetime
    /// goes through here. A load racing the release is a use-after-free, and
    /// even when it survives, the WindowServer may already have retired the ID.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The one divisor for both HiDPI and non-HiDPI. The old code switched
    /// between 220 and 110 PPI, but the HiDPI branch also doubled the pixel
    /// count, so both branches emitted an identical rect. Note that Retina-ness
    /// comes from maxPixelsWide versus the POINTS in the mode list, not from
    /// this physical size.
    private static let millimetersPerPixel = 25.4 / 110.0

    /// Releasing the display object is the only teardown this API offers (there
    /// is no destroy()), and it is not sufficient once the display has entered
    /// a configuration transaction: on macOS 26+ a display whose mode changed
    /// stays in Displays until the process exits, and nothing public can force
    /// it out. Teardown therefore waits a bounded moment and then reports what
    /// it actually observed instead of claiming success.
    private static let offlineTimeout: TimeInterval = 0.75
    private static let offlinePollInterval: TimeInterval = 0.01

    var displayID: CGDirectDisplayID? {
        state.withLock { $0.display?.displayID }
    }

    var isActive: Bool {
        state.withLock { $0.display != nil }
    }

    /// Create a virtual display with specified configuration
    /// - Parameters:
    ///   - width: Display width in pixels
    ///   - height: Display height in pixels
    ///   - refreshRate: Refresh rate in Hz (default: 60)
    ///   - hiDPI: Enable HiDPI mode (default: false)
    ///   - name: Display name (default: "Virtual Display")
    func createDisplay(
        width: Int,
        height: Int,
        refreshRate: Int = 60,
        hiDPI: Bool = false,
        name: String = "Virtual Display"
    ) throws {
        try Self.verifyAPIShape()

        // Clean up existing display if any
        destroyDisplay()

        let geometry = try VirtualDisplayLimits.resolve(
            width: width,
            height: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )

        // Create display descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(geometry.pixelsWide)
        descriptor.maxPixelsHigh = UInt32(geometry.pixelsHigh)
        descriptor.sizeInMillimeters = CGSize(
            width: Double(geometry.pixelsWide) * Self.millimetersPerPixel,
            height: Double(geometry.pixelsHigh) * Self.millimetersPerPixel
        )

        let productID = VirtualDisplayLimits.productID(
            pixelsWide: geometry.pixelsWide,
            pixelsHigh: geometry.pixelsHigh
        )
        descriptor.productID = productID
        descriptor.vendorID = Self.vendorID
        descriptor.serialNum = VirtualDisplaySerial.number(
            for: VirtualDisplaySerial.Seed(
                vendorID: Self.vendorID,
                productID: productID,
                pixelsWide: geometry.pixelsWide,
                pixelsHigh: geometry.pixelsHigh,
                refreshRate: refreshRate,
                hiDPI: hiDPI
            )
        )

        // Create display settings
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0

        // Two modes under HiDPI: the physical-size anchor (tells macOS the
        // panel is high-density, which is what unlocks HiDPI for the logical
        // mode) and the logical mode we actually want selected. Measured live
        // on macOS 27: the system picks the second and reports a backing scale
        // of 2.0 (1400x876 points / 2800x1752 pixels). Chromium passes a single
        // mode and lets macOS synthesise the variants, which is a reasonable
        // alternative, but this pair is the configuration verified working, so
        // it stays.
        var modes: [CGVirtualDisplayMode] = []
        if hiDPI {
            modes.append(CGVirtualDisplayMode(
                width: UInt32(geometry.pixelsWide),
                height: UInt32(geometry.pixelsHigh),
                refreshRate: geometry.refreshRate
            ))
        }
        modes.append(CGVirtualDisplayMode(
            width: UInt32(geometry.pointsWide),
            height: UInt32(geometry.pointsHigh),
            refreshRate: geometry.refreshRate
        ))
        settings.modes = modes

        // Create virtual display
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed("Failed to create CGVirtualDisplay")
        }

        state.withLock {
            $0.display = display
            $0.descriptor = descriptor
            $0.settings = settings
            $0.pointsSize = CGSize(width: geometry.pointsWide, height: geometry.pointsHigh)
        }

        // Apply settings
        let result = display.apply(settings)
        if !result {
            destroyDisplay()
            throw VirtualDisplayError.settingsApplyFailed("Failed to apply settings")
        }

        let modeDesc = hiDPI
            ? "\(geometry.pointsWide)x\(geometry.pointsHigh) HiDPI (physical \(geometry.pixelsWide)x\(geometry.pixelsHigh))"
            : "\(geometry.pointsWide)x\(geometry.pointsHigh)"
        print("✅ Virtual display created: \(modeDesc) @ \(geometry.refreshRate)Hz (ID: \(display.displayID), serial \(descriptor.serialNum))")

        registerScreenParamsObserver()
    }

    /// Re-assert the physical-main invariant on every display-topology change:
    /// WindowServer can re-adopt the virtual display as main from a remembered
    /// arrangement at any point after creation (issue #39), not only during
    /// the one-shot restore — e.g. when a physical display is hot-plugged.
    /// Our own re-arrangement re-fires the notification, but the main-display
    /// guard in ensurePhysicalDisplayStaysMain makes that pass a no-op.
    private func registerScreenParamsObserver() {
        let alreadyRegistered = state.withLock { $0.observer != nil }
        guard !alreadyRegistered else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensurePhysicalDisplayStaysMain()
        }
        state.withLock { $0.observer = token }
    }

    /// Clone the main display configuration
    func cloneMainDisplay() throws {
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID? else {
            throw VirtualDisplayError.mainDisplayNotFound
        }

        let width = Int(CGDisplayPixelsWide(mainDisplay))
        let height = Int(CGDisplayPixelsHigh(mainDisplay))

        // Get refresh rate
        var refreshRate = 60
        if let mode = CGDisplayCopyDisplayMode(mainDisplay) {
            refreshRate = Int(mode.refreshRate)
        }

        try createDisplay(
            width: width,
            height: height,
            refreshRate: refreshRate,
            name: "Virtual Display (Clone)"
        )
    }

    /// Enable mirror mode with main display
    func enableMirrorMode() throws {
        guard let display = state.withLock({ $0.display }) else {
            throw VirtualDisplayError.displayNotCreated
        }

        try applyMirroring(CGMainDisplayID(), action: "enable", to: display)
        state.withLock { $0.mirroringEnabled = true }
        print("✅ Mirror mode enabled")
    }

    /// Disable mirror mode (extend mode)
    func disableMirrorMode() throws {
        guard let display = state.withLock({ $0.display }) else {
            throw VirtualDisplayError.displayNotCreated
        }

        // kCGNullDirectDisplay disables mirroring
        try applyMirroring(
            CGDirectDisplayID(kCGNullDirectDisplay),
            action: "disable",
            to: display
        )
        state.withLock { $0.mirroringEnabled = false }
        print("✅ Extend mode enabled (mirror disabled)")
    }

    private func applyMirroring(_ mirrorOf: CGDirectDisplayID, action: String, to display: CGVirtualDisplay) throws {
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == .success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            config,
            display.displayID,
            mirrorOf
        )

        if mirrorResult != .success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.mirrorModeFailed("Failed to \(action) mirror mode: \(mirrorResult)")
        }

        // Session-scoped on purpose, matching setDisplayPosition: a permanent
        // mirror record outlives the app, and exiting while mirrored leaves
        // WindowServer's arrangement pointing at a display ID that no longer
        // exists.
        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)

        if completeResult != .success {
            throw VirtualDisplayError.mirrorModeFailed("Failed to complete mirror configuration: \(completeResult)")
        }
    }

    /// Get current display position (origin)
    func getDisplayPosition() -> CGPoint? {
        guard let displayID = displayID else { return nil }
        let bounds = CGDisplayBounds(displayID)
        // An offline display reports CGRectNull, and Int() on an infinite
        // coordinate traps.
        guard !bounds.isNull, bounds.origin.x.isFinite, bounds.origin.y.isFinite else { return nil }
        return bounds.origin
    }

    /// Set display position in arrangement
    func setDisplayPosition(x: Int32, y: Int32) throws {
        guard let display = state.withLock({ $0.display }) else {
            throw VirtualDisplayError.displayNotCreated
        }

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == .success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        let originResult = CGConfigureDisplayOrigin(config, display.displayID, x, y)

        if originResult != .success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.configurationFailed("Failed to set display origin: \(originResult)")
        }

        // Session-scoped on purpose: position is persisted via UserDefaults, and
        // baking the virtual display into WindowServer's permanent prefs lets the
        // system re-adopt it as main on later startups (#39).
        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)

        if completeResult != .success {
            throw VirtualDisplayError.configurationFailed("Failed to complete configuration: \(completeResult)")
        }

        print("📍 Display position set to (\(x), \(y))")
    }

    /// Save current display position to UserDefaults
    func saveDisplayPosition() {
        guard let position = getDisplayPosition() else { return }
        let defaults = UserDefaults.standard
        defaults.set(Int(position.x), forKey: "SideScreen_positionX")
        defaults.set(Int(position.y), forKey: "SideScreen_positionY")
        defaults.set(true, forKey: "SideScreen_hasPosition")
        print("💾 Saved display position: (\(Int(position.x)), \(Int(position.y)))")
    }

    /// Restore saved display position
    func restoreDisplayPosition() {
        // Run the main-display safety net on every path, including early
        // returns: WindowServer can re-adopt the virtual display as main from
        // its own remembered arrangement even when we restore nothing (#39).
        defer { ensurePhysicalDisplayStaysMain() }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "SideScreen_hasPosition") else {
            print("📍 No saved display position found")
            return
        }

        guard let virtual = displayID else { return }

        let x = defaults.integer(forKey: "SideScreen_positionX")
        let y = defaults.integer(forKey: "SideScreen_positionY")

        // A position saved under a different display topology is not a position
        // any more. CGConfigureDisplayOrigin accepts an arbitrary origin and
        // only nudges it "as close as possible", so a stale offset silently
        // parks the display past the edge of a desktop the user cannot scroll
        // to — the menu bar disappears and the Mac looks hung (#39 through a
        // different door). The old code only special-cased the main slot (0,0).
        let physicalBounds: [CGRect]
        switch queryPhysicalBounds(excluding: virtual) {
        case .unavailable(let error):
            print("⚠️  Skipping saved position restore — online display list unavailable: \(error)")
            return
        case .bounds(let bounds):
            physicalBounds = bounds
        }

        if physicalBounds.isEmpty {
            print("🛟 Headless — the virtual display keeps the main slot; saved position (\(x), \(y)) not applied")
            return
        }

        let current = CGDisplayBounds(virtual)
        let size = current.isNull || current.size.width <= 0 || current.size.height <= 0
            ? state.withLock { $0.pointsSize }
            : current.size

        guard VirtualDisplayPlacement.isReachable(
            savedOrigin: CGPoint(x: x, y: y),
            virtualSize: size,
            physicalBounds: physicalBounds
        ) else {
            print("🛟 Skipping saved position (\(x), \(y)) — it no longer adjoins any attached display")
            return
        }

        do {
            try setDisplayPosition(x: Int32(clamping: x), y: Int32(clamping: y))
            print("📍 Restored display position: (\(x), \(y))")
        } catch {
            print("⚠️  Failed to restore display position: \(error)")
        }
    }

    /// Outcome of a display enumeration. CGGetOnlineDisplayList can fail, and
    /// the guards below must not read that as "no physical displays": doing so
    /// turns a safety net into a no-op on exactly the transient failures it
    /// exists for.
    private enum OnlineList {
        case online([CGDirectDisplayID])
        case unavailable(CGError)
    }

    private enum PhysicalList {
        case bounds([CGRect])
        case unavailable(CGError)
    }

    private func queryDisplays() -> OnlineList {
        // The documented way to learn the real count: maxDisplays is a cap on
        // what gets written, so any fixed-size buffer truncates silently.
        var count: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &count)
        guard countResult == CGError.success else { return .unavailable(countResult) }
        guard count > 0 else { return .online([]) }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = CGGetOnlineDisplayList(count, &ids, &count)
        guard listResult == CGError.success else { return .unavailable(listResult) }
        return .online(ids.prefix(Int(count)).map { $0 })
    }

    private func queryPhysicalBounds(excluding virtual: CGDirectDisplayID?) -> PhysicalList {
        switch queryDisplays() {
        case .unavailable(let error):
            return .unavailable(error)
        case .online(let ids):
            return .bounds(
                ids.filter { isPhysicalDisplay($0, excluding: virtual) }.map { CGDisplayBounds($0) }
            )
        }
    }

    /// Online displays other than this virtual display. Filters by the vendor
    /// ID our descriptor registers so a stale SideScreen display from a
    /// previous instance is not mistaken for a physical screen, and by
    /// drawability: with the lid closed the built-in panel stays online while
    /// asleep, and CGGetOnlineDisplayList guarantees no ordering and no
    /// drawability, so promoting it to the main slot is #39 all over again.
    private func isPhysicalDisplay(_ id: CGDirectDisplayID, excluding virtual: CGDirectDisplayID?) -> Bool {
        guard id != virtual, CGDisplayVendorNumber(id) != Self.vendorID else { return false }
        return CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
    }

    /// True when any mirror relationship is in play, which
    /// CGConfigureDisplayOrigin would silently break: "setting the origin of a
    /// display which is mirroring another display will remove that display
    /// from any mirroring set".
    private func isMirroring(_ id: CGDirectDisplayID) -> Bool {
        if state.withLock({ $0.mirroringEnabled }) { return true }
        let noMirror = CGDirectDisplayID(kCGNullDirectDisplay)
        if CGDisplayMirrorsDisplay(id) != noMirror { return true }
        guard case .online(let ids) = queryDisplays() else { return false }
        return ids.contains { CGDisplayMirrorsDisplay($0) == id }
    }

    /// Safety net for #39: whenever at least one physical display is online,
    /// the main slot (0,0) must belong to a physical display, never to the
    /// virtual one. Otherwise the menu bar, dock, and keyboard focus land on a
    /// screen nobody can see, which presents as a completely unresponsive Mac.
    /// No-ops in true headless operation (no physical display online).
    func ensurePhysicalDisplayStaysMain() {
        guard let id = displayID else { return }
        guard CGMainDisplayID() == id else { return }

        guard !isMirroring(id) else {
            print("🛟 Skipping re-arrangement — display \(id) is mirroring; moving it would drop the mirror")
            return
        }

        let physicalIDs: [CGDirectDisplayID]
        switch queryDisplays() {
        case .unavailable(let error):
            // Fail closed: an enumeration failure is not evidence that the
            // Mac is headless.
            print("⚠️  Skipping physical-main guard — online display list unavailable: \(error)")
            return
        case .online(let ids):
            physicalIDs = ids.filter { isPhysicalDisplay($0, excluding: id) }
        }

        // CGGetOnlineDisplayList is ascending by display ID, not main-first, so
        // "the first physical display" is an arbitrary monitor. Ask which one
        // actually holds the main slot.
        let bounds = physicalIDs.map { CGDisplayBounds($0) }
        guard let mainIndex = VirtualDisplayPlacement.mainSlotOwner(in: bounds) else { return }
        let physicalMain = physicalIDs[mainIndex]
        let physicalWidth = originComponent(bounds[mainIndex].width)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config = config else { return }

        // Give the physical display the main slot and park the virtual display
        // to its right. CGConfigureDisplayOrigin repositions ANY display whose
        // origin is not explicitly set in the transaction, so every other
        // physical display is pinned where the user put it — otherwise a second
        // monitor gets shuffled as a side effect of this guard.
        var result = CGConfigureDisplayOrigin(config, physicalMain, 0, 0)
        if result == .success {
            result = CGConfigureDisplayOrigin(config, id, physicalWidth, 0)
        }
        if result == .success {
            for (index, other) in physicalIDs.enumerated() where index != mainIndex {
                let origin = bounds[index].origin
                result = CGConfigureDisplayOrigin(
                    config,
                    other,
                    originComponent(origin.x),
                    originComponent(origin.y)
                )
                if result != .success { break }
            }
        }
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            print("⚠️  Failed to rearrange displays: \(result)")
            return
        }

        if CGCompleteDisplayConfiguration(config, .forSession) == .success {
            print("🛟 Physical display restored as main — virtual display parked beside it")
        }
    }

    /// Int32(exact-conversion) traps on a non-finite coordinate, and this runs
    /// as a safety guard, so it never gets to be the thing that crashes.
    private func originComponent(_ value: CGFloat) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(clamping: Int(value))
    }

    /// Verify the virtual display is registered in the system display list
    func verifyDisplayRegistered() -> Bool {
        guard let displayID = displayID else {
            debugLog("verifyDisplayRegistered: no displayID set")
            return false
        }

        let ids: [CGDirectDisplayID]
        switch queryDisplays() {
        case .unavailable(let error):
            debugLog("verifyDisplayRegistered: CGGetOnlineDisplayList failed with \(error)")
            return false
        case .online(let online):
            ids = online
        }

        let found = ids.contains(displayID)
        debugLog("verifyDisplayRegistered: displayID \(displayID) \(found ? "FOUND" : "NOT FOUND") in online displays \(ids)")
        return found
    }

    /// Holds a display that has left the locked state but is not yet released:
    /// the mirror restore needs the object, and dropping the reference is the
    /// teardown, so the two steps have to be separable.
    private final class RetiredDisplay {
        private var display: CGVirtualDisplay?
        let id: CGDirectDisplayID
        let mirrorWasEnabled: Bool

        init(_ display: CGVirtualDisplay, mirrorWasEnabled: Bool) {
            self.display = display
            self.id = display.displayID
            self.mirrorWasEnabled = mirrorWasEnabled
        }

        var live: CGVirtualDisplay? { display }

        func release() {
            display = nil
        }
    }

    /// Destroy the virtual display
    func destroyDisplay() {
        let retired: RetiredDisplay? = state.withLock { state in
            guard let live = state.display else { return nil }
            let retired = RetiredDisplay(live, mirrorWasEnabled: state.mirroringEnabled)
            if let token = state.observer {
                NotificationCenter.default.removeObserver(token)
            }
            state.observer = nil
            state.display = nil
            state.descriptor = nil
            state.settings = nil
            state.mirroringEnabled = false
            state.pointsSize = .zero
            return retired
        }
        guard let retired else { return }

        // Restore extend mode while the display is still alive: leaving a
        // mirror relationship pointing at a retired display ID is what makes
        // the arrangement unusable on the next login.
        if retired.mirrorWasEnabled, let live = retired.live {
            do {
                try applyMirroring(
                    CGDirectDisplayID(kCGNullDirectDisplay),
                    action: "release",
                    to: live
                )
                print("✅ Mirror mode released before teardown")
            } catch {
                print("⚠️  Failed to release mirror mode before teardown: \(error)")
            }
        }

        // Releasing the last reference IS the teardown: this API has no
        // destroy(), so the offline poll below has to come after the release.
        retired.release()

        if waitUntilOffline(retired.id) {
            print("🗑️  Virtual display destroyed")
        } else {
            print("🗑️  Virtual display released, but display \(retired.id) is still online")
            print("⚠️  A display that has entered a configuration transaction cannot be removed until the process exits — restart to clear it")
        }
    }

    /// Nothing public can force a still-online display out, so this only
    /// observes. Returns false when the display is still present, and also when
    /// the enumeration itself failed: both mean "removal not confirmed".
    private func waitUntilOffline(_ id: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(Self.offlineTimeout)
        while true {
            switch queryDisplays() {
            case .online(let ids) where !ids.contains(id):
                return true
            case .online:
                break
            case .unavailable(let error):
                debugLog("waitUntilOffline: display list unavailable: \(error)")
                return false
            }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: Self.offlinePollInterval)
        }
    }

    deinit {
        // Runs off the main thread at process exit, which is fine: the teardown
        // only touches NotificationCenter and the WindowServer, both thread-safe,
        // and it must not hop — there may be no run loop left to hop to.
        destroyDisplay()
    }

    // MARK: - Private API shape

    /// Required classes and selectors of the private bridge. Sending a message
    /// to a class that no longer exists, or to a selector a class no longer
    /// implements, is a hard crash in the Objective-C runtime rather than an
    /// error return — so a point release that reshapes this API would take the
    /// app down at launch instead of disabling the feature with a message.
    static let apiShape: [(class: String, selectors: [String])] = [
        ("CGVirtualDisplayDescriptor", [
            "setName:",
            "setVendorID:",
            "setProductID:",
            "setSerialNum:",
            "setSizeInMillimeters:",
            "setMaxPixelsWide:",
            "setMaxPixelsHigh:"
        ]),
        ("CGVirtualDisplayMode", [
            "initWithWidth:height:refreshRate:"
        ]),
        ("CGVirtualDisplaySettings", [
            "setHiDPI:",
            "setModes:"
        ]),
        ("CGVirtualDisplay", [
            "initWithDescriptor:",
            "applySettings:",
            "displayID"
        ])
    ]

    static func verifyAPIShape() throws {
        for requirement in apiShape {
            guard let cls = NSClassFromString(requirement.class) else {
                throw VirtualDisplayError.unsupportedOS("Private display API class \(requirement.class) is unavailable")
            }
            for selector in requirement.selectors
            where class_getInstanceMethod(cls, NSSelectorFromString(selector)) == nil {
                throw VirtualDisplayError.unsupportedOS(
                    "Private display API \(requirement.class) is missing \(selector)"
                )
            }
        }
    }
}

// MARK: - Error Types
enum VirtualDisplayError: Error, LocalizedError {
    case creationFailed(String)
    case settingsApplyFailed(String)
    case displayNotCreated
    case mainDisplayNotFound
    case configurationFailed(String)
    case mirrorModeFailed(String)
    case invalidGeometry(String)
    case unsupportedOS(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let msg):
            return "Virtual display creation failed: \(msg)"
        case .settingsApplyFailed(let msg):
            return "Settings apply failed: \(msg)"
        case .displayNotCreated:
            return "Virtual display has not been created"
        case .mainDisplayNotFound:
            return "Main display not found"
        case .configurationFailed(let msg):
            return "Display configuration failed: \(msg)"
        case .mirrorModeFailed(let msg):
            return "Mirror mode operation failed: \(msg)"
        case .invalidGeometry(let msg):
            return "Invalid display size requested: \(msg)"
        case .unsupportedOS(let msg):
            return "Virtual display unavailable on this macOS version: \(msg)"
        }
    }
}

// MARK: - Geometry limits

/// Bounds applied before anything reaches the WindowServer: UInt32(negative)
/// traps rather than wrapping, and a mode larger than the descriptor's maximum
/// is rejected outright.
enum VirtualDisplayLimits {
    static let minDimension = 64
    static let maxDimension = 16384
    static let minRefreshRate = 1.0
    static let maxRefreshRate = 960.0

    struct Geometry: Equatable {
        let pointsWide: Int
        let pointsHigh: Int
        let pixelsWide: Int
        let pixelsHigh: Int
        let refreshRate: Double
    }

    static func resolve(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) throws -> Geometry {
        guard width > 0, height > 0 else {
            throw VirtualDisplayError.invalidGeometry("width and height must be positive, got \(width)x\(height)")
        }
        guard refreshRate > 0 else {
            throw VirtualDisplayError.invalidGeometry("refresh rate must be positive, got \(refreshRate)")
        }

        let scale = hiDPI ? 2 : 1
        // Under HiDPI the physical size is what must stay inside the API
        // bound, so the logical size is capped at half of it and the two modes
        // stay distinct.
        let ceiling = hiDPI ? maxDimension / scale : maxDimension
        let pointsWide = min(max(width, minDimension), ceiling)
        let pointsHigh = min(max(height, minDimension), ceiling)

        return Geometry(
            pointsWide: pointsWide,
            pointsHigh: pointsHigh,
            pixelsWide: pointsWide * scale,
            pixelsHigh: pointsHigh * scale,
            refreshRate: min(max(Double(refreshRate), minRefreshRate), maxRefreshRate)
        )
    }

    /// Height is packed into the low digits of width so (3840,2400) and
    /// (2400,3840) cannot collide. Verified to round-trip: the largest
    /// descriptor-accepted size is 16384*10000 + 16384, well inside UInt32.
    static func productID(pixelsWide: Int, pixelsHigh: Int) -> UInt32 {
        UInt32(pixelsWide * 10000 + pixelsHigh)
    }
}

// MARK: - Identity

/// macOS keys remembered per-display state on the (vendor, product, serial)
/// triple, so a constant serial makes every SideScreen display the same monitor
/// to the OS — Chromium, verbatim: "macOS 14 expects different virtual displays
/// to have different serial numbers". The value must be stable across runs
/// (that is what makes the system remember a mode) and distinct per distinct
/// configuration, so it is a pure hash of the configuration.
enum VirtualDisplaySerial {
    struct Seed: Equatable {
        let vendorID: UInt32
        let productID: UInt32
        let pixelsWide: Int
        let pixelsHigh: Int
        let refreshRate: Int
        let hiDPI: Bool
    }

    static func number(for seed: Seed) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes(of: seed) {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        // 0 is how an unset serialNum reads; keep it out of the range.
        return hash == 0 ? 1 : hash
    }

    private static func bytes(of seed: Seed) -> [UInt8] {
        var encoded: [UInt8] = []
        encoded.append(contentsOf: bigEndian(seed.vendorID))
        encoded.append(contentsOf: bigEndian(seed.productID))
        encoded.append(contentsOf: bigEndian(UInt32(truncatingIfNeeded: seed.pixelsWide)))
        encoded.append(contentsOf: bigEndian(UInt32(truncatingIfNeeded: seed.pixelsHigh)))
        encoded.append(contentsOf: bigEndian(UInt32(truncatingIfNeeded: seed.refreshRate)))
        encoded.append(seed.hiDPI ? 1 : 0)
        return encoded
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }
}

// MARK: - Placement geometry

/// Pure geometry behind the #39 guard and the position restore. Both used to
/// guess: which display owns the main slot (the online list is ordered by
/// display ID, not main-first) and whether a saved origin is still a location
/// the user can reach.
enum VirtualDisplayPlacement {
    /// Integer origins, integer display sizes: a one pixel slack is enough.
    private static let tolerance: CGFloat = 1

    /// Index of the display that currently holds the main slot: the one whose
    /// bounds contain (0,0), else the one closest to it, with ties broken by
    /// position in the list so the choice never depends on enumeration order
    /// alone.
    static func mainSlotOwner(in bounds: [CGRect]) -> Int? {
        guard !bounds.isEmpty else { return nil }
        if let containing = bounds.firstIndex(where: { $0.contains(CGPoint.zero) }) {
            return containing
        }
        return bounds.indices.min { lhs, rhs in
            let a = bounds[lhs].origin
            let b = bounds[rhs].origin
            let distanceA = a.x * a.x + a.y * a.y
            let distanceB = b.x * b.x + b.y * b.y
            if distanceA != distanceB { return distanceA < distanceB }
            return lhs < rhs
        }
    }

    /// Whether a saved origin is still a position the desktop can reach, given
    /// the displays attached now. Reachable means the display adjoins an
    /// attached one without covering it: sharing an edge is fine (the desktop
    /// grows), floating past the edge is not (the user cannot scroll to a gap),
    /// and landing on top of an attached display is the arrangement that hides
    /// the menu bar (#39).
    static func isReachable(savedOrigin: CGPoint, virtualSize: CGSize, physicalBounds: [CGRect]) -> Bool {
        guard !physicalBounds.isEmpty,
              virtualSize.width > 0,
              virtualSize.height > 0 else { return false }
        let candidate = CGRect(origin: savedOrigin, size: virtualSize)
        return physicalBounds.contains { adjoins($0, candidate) }
    }

    private static func adjoins(_ desktop: CGRect, _ candidate: CGRect) -> Bool {
        let overlap = desktop.intersection(candidate)
        // Interiors must not intersect: a shared edge is a legitimate stack,
        // a shared area is an overlap.
        if overlap.width > tolerance && overlap.height > tolerance { return false }
        return desktop.insetBy(dx: -tolerance, dy: -tolerance).intersects(candidate)
    }
}
