import XCTest
@testable import SideScreen

/// Night Shift -> Samsung Eye comfort shield. The fake tablet below models
/// what BlueLightFilterService does with each `settings put` (decompiled
/// from SM-X800's BlueLightFilter.apk): the panel level only changes when
/// the shield is on, "Set schedule" is on and the type is Always on (0).
final class NightShiftTabletFilterTests: XCTestCase {
    // MARK: - Strength mapping

    func testStrengthMapsOntoTheZeroToTenSlider() {
        XCTAssertEqual(NightShiftTarget.level(forStrength: 0), 0)
        XCTAssertEqual(NightShiftTarget.level(forStrength: 0.5), 5)
        XCTAssertEqual(NightShiftTarget.level(forStrength: 0.883), 9)
        XCTAssertEqual(NightShiftTarget.level(forStrength: 1), 10)
    }

    func testStrengthClampsAndRejectsNonFinite() {
        XCTAssertEqual(NightShiftTarget.level(forStrength: -0.4), 0)
        XCTAssertEqual(NightShiftTarget.level(forStrength: 1.6), 10)
        XCTAssertEqual(NightShiftTarget.level(forStrength: .nan), 0)
        XCTAssertEqual(NightShiftTarget.level(forStrength: .infinity), 0)
    }

    func testInactiveOrUnreadableNightShiftIsOff() {
        XCTAssertEqual(NightShiftTarget.target(for: nil), .off)
        let daytime = NightShiftReading(active: false, strength: 0.9, kelvin: 6_500)
        XCTAssertEqual(NightShiftTarget.target(for: daytime), .off)
        let night = NightShiftReading(active: true, strength: 0.883, kelvin: 3_028)
        XCTAssertEqual(NightShiftTarget.target(for: night), NightShiftTarget(enabled: true, level: 9))
    }

    // MARK: - Planning

    func testShowSwitchesToAlwaysOnWithTheSwitchesLast() {
        let current = EyeComfortSettings(filter: 1, level: 88, scheduled: 0, type: 2)
        XCTAssertEqual(
            EyeComfortPlan.writes(toShow: 9, over: current).map(\.key),
            ["blue_light_filter_type", "blue_light_filter_opacity", "blue_light_filter_scheduled"]
        )
    }

    func testStrengthOnlyChangeIsOneLevelWrite() {
        let current = EyeComfortSettings(filter: 1, level: 9, scheduled: 1, type: 0)
        XCTAssertEqual(
            EyeComfortPlan.writes(toShow: 6, over: current),
            [EyeComfortPlan.Write(key: "blue_light_filter_opacity", value: 6)]
        )
        XCTAssertEqual(EyeComfortPlan.writes(toShow: 9, over: current), [])
    }

    func testRestoreTurnsOffBeforeTouchingTheSchedule() {
        let current = EyeComfortSettings(filter: 1, level: 9, scheduled: 1, type: 0)
        let saved = EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2)
        let phases = EyeComfortPlan.restorePhases(from: current, to: saved)
        XCTAssertEqual(phases.off, [EyeComfortPlan.Write(key: "blue_light_filter", value: 0)])
        XCTAssertEqual(phases.restore.map(\.key), [
            "blue_light_filter_opacity", "blue_light_filter_type", "blue_light_filter_scheduled"
        ])
    }

    // MARK: - Parsing

    func testParsesProbeOutput() {
        let output = """
        serial=R52X30G5TNB\r
        adb: stray warning on stderr\r
        sidetab=1\r
        blue_light_filter=1\r
        blue_light_filter_opacity=88\r
        blue_light_filter_scheduled=0\r
        blue_light_filter_type=2\r

        """
        let probe = EyeComfortPlan.parseProbe(output)
        XCTAssertEqual(probe, EyeComfortPlan.Probe(
            serialNumber: "R52X30G5TNB",
            hasSideTab: true,
            settings: EyeComfortSettings(filter: 1, level: 88, scheduled: 0, type: 2)
        ))
    }

    func testNonSamsungTabletHasNoSettings() {
        let probe = EyeComfortPlan.parseProbe("""
        serial=ABC
        sidetab=1
        blue_light_filter=null
        blue_light_filter_opacity=null
        blue_light_filter_scheduled=null
        blue_light_filter_type=null
        """)
        XCTAssertNotNil(probe)
        XCTAssertNil(probe?.settings)
        XCTAssertNil(EyeComfortPlan.parseProbe("error: closed\n"))
        XCTAssertNil(EyeComfortPlan.parseProbe("serial=\nsidetab=1\n"))
    }

    func testReadySerialsPutUSBFirstAndDropUnready() {
        let output = """
        List of devices attached
        192.168.1.9:5555       device product:gts8 model:SM_X800 transport_id:7
        R52X30G5TNB            device usb:2097152X product:gts8 model:SM_X800 transport_id:6
        ZZZ                    unauthorized usb:1-1 transport_id:8

        """
        XCTAssertEqual(
            EyeComfortPlan.readySerials(fromDevicesOutput: output),
            ["R52X30G5TNB", "192.168.1.9:5555"]
        )
    }

    // MARK: - End to end against a fake tablet

    func testNightShiftDrivesThePanelAndRestoresTheUsersSettings() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))
        let store = makeStore()
        let filter = makeFilter(tablet, store)

        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.panelLevel, 9)
        XCTAssertEqual(store.snapshot(for: "R52"), EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))

        filter.show(NightShiftTarget(enabled: true, level: 4))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.panelLevel, 4)
        XCTAssertEqual(tablet.writeCount, 5, "a strength change is one write")

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertNil(tablet.panelLevel, "panel must not stay warm")
        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))
        XCTAssertNil(store.snapshot(for: "R52"))
    }

    func testSnapshotSurvivesARelaunch() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 1, level: 2, scheduled: 1, type: 2))
        let defaults = makeDefaults()
        let first = makeFilter(tablet, EyeComfortSnapshotStore(defaults: defaults))
        first.show(NightShiftTarget(enabled: true, level: 7))
        XCTAssertTrue(first.waitUntilIdle(timeout: 2))

        // A new process reading the same defaults must not re-snapshot the
        // mirror's own state as the user's.
        let second = makeFilter(tablet, EyeComfortSnapshotStore(defaults: defaults))
        second.show(NightShiftTarget(enabled: true, level: 8))
        XCTAssertTrue(second.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.panelLevel, 8)
        second.release()
        XCTAssertTrue(second.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 1, level: 2, scheduled: 1, type: 2))
        XCTAssertFalse(second.hasPendingRestores)
    }

    func testUnpluggedTabletKeepsItsSnapshotForALaterRelease() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))
        var plugged = true
        let filter = NightShiftTabletFilter(
            listDevices: { plugged ? "List of devices attached\nR52 device usb:1-1\n" : "List of devices attached\n" },
            shell: { _, script in tablet.run(script) },
            snapshots: makeStore(),
            pause: { _ in }
        )
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        plugged = false
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertTrue(filter.hasPendingRestores, "a missed release must stay pending")

        plugged = true
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertFalse(filter.hasPendingRestores)
        XCTAssertNil(tablet.panelLevel)
        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))
    }

    func testReleaseWithoutASnapshotLeavesTheTabletAlone() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 1, level: 5, scheduled: 0, type: 2))
        let filter = makeFilter(tablet, makeStore())
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.writeCount, 0)
    }

    func testTabletWithoutSideTabIsNotTouched() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 0, scheduled: 0, type: 0))
        tablet.hasSideTab = false
        let filter = makeFilter(tablet, makeStore())
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.writeCount, 0)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suite = "NightShiftTabletFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeStore() -> EyeComfortSnapshotStore {
        EyeComfortSnapshotStore(defaults: makeDefaults())
    }

    private func makeFilter(_ tablet: FakeSamsungTablet, _ store: EyeComfortSnapshotStore) -> NightShiftTabletFilter {
        NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            shell: { _, script in tablet.run(script) },
            snapshots: store,
            pause: { _ in tablet.settle() }
        )
    }
}

/// Settings.System plus the observer behavior that decides what the panel
/// shows. `settle()` stands in for the observer catching up between adb
/// calls; within one shell script the observer sees only the final values.
private final class FakeSamsungTablet {
    var settings: EyeComfortSettings
    var hasSideTab = true
    private(set) var panelLevel: Int?
    private(set) var writeCount = 0

    init(_ settings: EyeComfortSettings) {
        self.settings = settings
        panelLevel = nil
    }

    func run(_ script: String) -> String? {
        if script == EyeComfortPlan.probeScript {
            let s = settings
            return """
            serial=R52
            sidetab=\(hasSideTab ? 1 : 0)
            blue_light_filter=\(s.filter)
            blue_light_filter_opacity=\(s.level)
            blue_light_filter_scheduled=\(s.scheduled)
            blue_light_filter_type=\(s.type)

            """
        }
        var touched: [String] = []
        for command in script.components(separatedBy: " && ") {
            let parts = command.split(separator: " ").map(String.init)
            guard parts.count == 5, parts[0] == "settings", parts[1] == "put",
                  let value = Int(parts[4]) else { return nil }
            switch parts[3] {
            case EyeComfortPlan.keyFilter: settings.filter = value
            case EyeComfortPlan.keyLevel: settings.level = value
            case EyeComfortPlan.keyScheduled: settings.scheduled = value
            case EyeComfortPlan.keyType: settings.type = value
            default: return nil
            }
            touched.append(parts[3])
            writeCount += 1
        }
        observe(touched)
        return ""
    }

    func settle() {}

    /// BlueLightFilterService.onChange, reduced to the Always-on path.
    private func observe(_ keys: [String]) {
        let s = settings
        if s.filter == 0 {
            if keys.contains(EyeComfortPlan.keyFilter), s.scheduled != 0 { panelLevel = nil }
            return
        }
        if s.scheduled != 0, s.type == EyeComfortPlan.typeAlwaysOn { panelLevel = s.level }
    }
}
