import XCTest
@testable import SideScreen

/// Night Shift -> Samsung Eye comfort shield. The fake tablet below models
/// SM-X800's BlueLightFilterService (decompiled BlueLightFilter.apk) in its
/// usual stopped state: settings writes alone change nothing, and the panel
/// follows only the service starts that Samsung's Settings app also sends.
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

    func testInactiveNightShiftIsOffAndUnreadableHostIsUnknown() {
        XCTAssertNil(NightShiftTarget.target(for: nil))
        let daytime = NightShiftReading(active: false, automaticScheduleEnabled: false, strength: 0.9, kelvin: 6_500)
        XCTAssertEqual(NightShiftTarget.target(for: daytime), .off)
        let night = NightShiftReading(active: true, automaticScheduleEnabled: true, strength: 0.883, kelvin: 3_028)
        XCTAssertEqual(NightShiftTarget.target(for: night), NightShiftTarget(enabled: true, level: 9))
    }

    func testArmedScheduleAloneDoesNotForceTheFilterOn() {
        // Regression for the forced-on mirror: `AutoBlueReductionEnabled`
        // stays true all day because the schedule is armed. Only
        // `BlueReductionEnabled` (`active` here) means the Mac is warm now.
        let armedButInactive = NightShiftReading(
            active: false,
            automaticScheduleEnabled: true,
            strength: 0.883,
            kelvin: 3_028
        )
        XCTAssertEqual(NightShiftTarget.target(for: armedButInactive), .off)
    }


    func testMonitorDoesNotTreatAnUnreadableHostProbeAsMacOff() async {
        await MainActor.run {
            var reading: NightShiftReading?
            var emissions: [NightShiftTarget] = []
            let monitor = NightShiftMonitor(pollS: 60, probe: { reading })
            monitor.onChange = { emissions.append($0) }

            monitor.tick()
            XCTAssertTrue(emissions.isEmpty, "unknown must not take ownership as a synthetic Mac-off state")

            reading = NightShiftReading(active: true, automaticScheduleEnabled: true, strength: 0.883, kelvin: 3_028)
            monitor.tick()
            XCTAssertEqual(emissions, [NightShiftTarget(enabled: true, level: 9)])

            reading = nil
            monitor.tick()
            XCTAssertEqual(emissions.count, 1, "losing the probe mid-session must not rewrite the tablet")
        }
    }

    func testMonitorReconcileReemitsTheCurrentKnownTarget() async {
        await MainActor.run {
            let reading = NightShiftReading(active: false, automaticScheduleEnabled: true, strength: 0.883, kelvin: 3_028)
            var emissions: [NightShiftTarget] = []
            let monitor = NightShiftMonitor(pollS: 60, probe: { reading })
            monitor.onChange = { emissions.append($0) }
            monitor.tick()
            monitor.tick()
            XCTAssertEqual(emissions, [.off])
            monitor.reconcile()
            XCTAssertEqual(emissions, [.off, .off])
        }
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

    func testShowAlwaysStartsTheServiceEvenWhenKeysMatch() {
        let current = EyeComfortSettings(filter: 1, level: 9, scheduled: 1, type: 0)
        XCTAssertEqual(
            EyeComfortPlan.showScript(level: 9, over: current),
            "am startservice -n com.samsung.android.bluelightfilter/.BlueLightFilterService"
                + " --ei BLUE_LIGHT_FILTER_SERVICE_TYPE 24 >/dev/null"
        )
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
        blue_light_filter_adaptive_mode=1\r

        """
        let probe = EyeComfortPlan.parseProbe(output)
        XCTAssertEqual(probe, EyeComfortPlan.Probe(
            serialNumber: "R52X30G5TNB",
            hasSideTab: true,
            settings: EyeComfortSettings(filter: 1, level: 88, scheduled: 0, type: 2, adaptive: 1)
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
        XCTAssertEqual(tablet.writeCount, 5, "4 writes to take over, then 1 per strength change")

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertNil(tablet.panelLevel, "panel must not stay warm")
        XCTAssertEqual(
            tablet.settings,
            EyeComfortSettings(filter: 0, level: 4, scheduled: 1, type: 0),
            "Mac-off must force the tablet off while the session remains mirrored"
        )
        XCTAssertNotNil(store.snapshot(for: "R52"), "off is not a release; the user settings stay saved")

        filter.show(NightShiftTarget(enabled: true, level: 6))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.panelLevel, 6)

        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2))
        XCTAssertNil(store.snapshot(for: "R52"))
    }

    func testMacOffBeforeFirstOnStillSnapshotsAndTurnsTheUsersFilterOff() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 1, level: 5, scheduled: 1, type: 2))
        let store = makeStore()
        let filter = makeFilter(tablet, store)

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertNil(tablet.panelLevel)
        XCTAssertEqual(tablet.settings.filter, 0)
        XCTAssertEqual(store.snapshot(for: "R52"), EyeComfortSettings(filter: 1, level: 5, scheduled: 1, type: 2))

        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 1, level: 5, scheduled: 1, type: 2))
        XCTAssertFalse(filter.hasPendingRestores)
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
            listDevices: { plugged ? "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" : "List of devices attached\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: makeStore(),
            pause: { _ in tablet.settle() }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
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


    func testShowForcesAdaptiveModeOffBeforeCustomMirroring() {
        let current = EyeComfortSettings(filter: 1, level: 8, scheduled: 0, type: 2, adaptive: 1)
        XCTAssertEqual(
            EyeComfortPlan.writes(toShow: 9, over: current).map(\.key),
            [
                "blue_light_filter_adaptive_mode",
                "blue_light_filter_type",
                "blue_light_filter_opacity",
                "blue_light_filter_scheduled"
            ]
        )
    }

    func testRestoreAlwaysQueuesPanelOffEvenWhenFilterKeyAlreadyReadsOff() {
        let current = EyeComfortSettings(filter: 0, level: 9, scheduled: 1, type: 0, adaptive: 0)
        let saved = EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2, adaptive: 1)
        let phases = EyeComfortPlan.restorePhases(from: current, to: saved)
        XCTAssertEqual(phases.off.first, EyeComfortPlan.Write(key: "blue_light_filter", value: 0))
        XCTAssertEqual(phases.restore.map(\.key), [
            "blue_light_filter_opacity",
            "blue_light_filter_type",
            "blue_light_filter_scheduled",
            "blue_light_filter",
            "blue_light_filter_adaptive_mode"
        ])
        let scripts = EyeComfortPlan.restoreScripts(from: current, to: saved)
        XCTAssertNotNil(scripts.off)
        XCTAssertFalse(scripts.restore?.contains("BLUE_LIGHT_FILTER_SERVICE_TYPE 24") ?? true,
                       "Adaptive restore must not use Samsung's Custom-only type-24 apply")
    }

    func testAdaptiveUserIsForcedToCustomAndRestoredThroughAsynchronousServiceRace() {
        let original = EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2, adaptive: 1)
        let tablet = FakeSamsungTablet(original)
        tablet.autoSettle = false
        let store = makeStore()
        var pauseCount = 0
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: store,
            pause: { _ in
                pauseCount += 1
                tablet.settle()
            }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))

        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.settings.adaptive, 0)
        XCTAssertEqual(tablet.settings.type, EyeComfortPlan.typeAlwaysOn)
        XCTAssertEqual(store.snapshot(for: "R52"), original)

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertEqual(pauseCount, 1, "release must wait for the unconditional panel-off phase even when filter already reads 0")
        XCTAssertEqual(tablet.settings, original)
        XCTAssertTrue(tablet.adaptiveActive)
        XCTAssertEqual(tablet.panelLevel, 7)
        XCTAssertFalse(filter.hasPendingRestores)
    }

    func testMultipleMatchingUSBTabletsAreNotTouched() {
        let first = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let second = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2), serial: "R53")
        let devices = """
        List of devices attached
        R52 device usb:1-1 model:SM_X800
        R53 device usb:1-2 model:SM_X800

        """
        let filter = NightShiftTabletFilter(
            listDevices: { devices },
            reverseList: reverseMappingForTests,
            shell: { serial, script in (serial == "R52" ? first : second).run(script) },
            snapshots: makeStore(),
            pause: { _ in }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(first.writeCount, 0)
        XCTAssertEqual(second.writeCount, 0)
        XCTAssertTrue(filter.needsReconciliation)
    }


    func testFirstMacOffForcesAdaptiveUnscheduledTabletIntoServiceCompatibleOff() {
        let original = EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2, adaptive: 1)
        let tablet = FakeSamsungTablet(original)
        let store = makeStore()
        let filter = makeFilter(tablet, store)

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertEqual(tablet.settings, EyeComfortSettings(filter: 0, level: 7, scheduled: 1, type: 0, adaptive: 0))
        XCTAssertNil(tablet.panelLevel)
        XCTAssertFalse(tablet.adaptiveActive)
        XCTAssertEqual(store.snapshot(for: "R52"), original)
    }

    func testLegacySnapshotIsAugmentedWithAdaptiveBeforeFirstOverride() {
        let live = EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2, adaptive: 1)
        let tablet = FakeSamsungTablet(live)
        let store = makeStore()
        store.save(EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2), for: "R52")
        let filter = makeFilter(tablet, store)

        filter.show(.off)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(store.snapshot(for: "R52")?.adaptive, 1)

        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.settings, live)
        XCTAssertTrue(tablet.adaptiveActive)
    }

    func testRestoreDoesNotRewriteUserKeysUntilPanelOffExecutionIsObserved() {
        let original = EyeComfortSettings(filter: 1, level: 7, scheduled: 1, type: 0, adaptive: 0)
        let tablet = FakeSamsungTablet(original)
        tablet.autoSettle = false
        let store = makeStore()
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: store,
            pause: { _ in }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))

        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertTrue(filter.hasPendingRestores)
        XCTAssertEqual(store.snapshot(for: "R52"), original)
        XCTAssertEqual(tablet.settings.scheduled, 1)
        XCTAssertEqual(tablet.settings.type, EyeComfortPlan.typeAlwaysOn)
        XCTAssertEqual(tablet.settings.level, 9)
    }


    func testAdbWirelessSerialHostParsingIsConservative() {
        XCTAssertEqual(EyeComfortPlan.adbSerialHost("192.168.1.8:5555"), "192.168.1.8")
        XCTAssertEqual(EyeComfortPlan.adbSerialHost("[fe80::1%en0]:5555"), "fe80::1")
        XCTAssertNil(EyeComfortPlan.adbSerialHost("R52X30G5TNB"))
        XCTAssertNil(EyeComfortPlan.adbSerialHost("fe80::1:5555"))
        XCTAssertEqual(EyeComfortPlan.normalizedHost("[FE80::1%en0]"), "fe80::1")
    }

    func testWirelessScopeDoesNotUseAUSBTransportEvenWhenModelMatches() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: makeStore(),
            pause: { _ in }
        )
        filter.setClientScope(.wireless(deviceModel: "SM-X800", clientHost: "192.168.1.8"))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.writeCount, 0)
        XCTAssertTrue(filter.needsReconciliation)
    }

    func testRestoreKeepsSnapshotWhenVerifiedOffStateDoesNotMatch() {
        let original = EyeComfortSettings(filter: 1, level: 7, scheduled: 1, type: 0, adaptive: 0)
        let tablet = FakeSamsungTablet(original)
        let store = makeStore()
        let filter = makeFilter(tablet, store)
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        // Simulate a user racing Settings after the off intent executes:
        // execution is observable, but the deterministic mirror state is no
        // longer present when the pre-restore verification probes it.
        tablet.changeScheduledToZeroAfterOff = true
        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertTrue(filter.hasPendingRestores)
        XCTAssertEqual(store.snapshot(for: "R52"), original)
    }


    func testDirectReleaseOfLegacySnapshotRestoresPreOffAdaptiveMode() {
        // A stranded override from the pre-Adaptive-model implementation left
        // the live Adaptive key untouched. The legacy snapshot lacks that key.
        let original = EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2, adaptive: 1)
        let strandedMirrorState = EyeComfortSettings(filter: 1, level: 9, scheduled: 1, type: 0, adaptive: 1)
        let tablet = FakeSamsungTablet(strandedMirrorState)
        let store = makeStore()
        store.save(EyeComfortSettings(filter: 1, level: 7, scheduled: 0, type: 2), for: "R52")
        let filter = makeFilter(tablet, store)

        filter.release()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertEqual(tablet.settings, original)
        XCTAssertTrue(tablet.adaptiveActive)
        XCTAssertFalse(filter.hasPendingRestores)
    }

    func testUSBControlFailsClosedWhenNonSamsungStreamingTransportIsAlsoPresent() {
        let samsung = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let devices = """
        List of devices attached
        R52 device usb:1-1 model:SM_X800
        PIXEL8 device usb:1-2 model:Pixel_8

        """
        let filter = NightShiftTabletFilter(
            listDevices: { devices },
            reverseList: { serial in serial == "PIXEL8" ? self.reverseMappingForTests(serial) : nil },
            shell: { serial, script in
                if serial == "PIXEL8", script == EyeComfortPlan.probeScript {
                    return """
                    serial=PIXEL8
                    sidetab=1
                    blue_light_filter=null
                    blue_light_filter_opacity=null
                    blue_light_filter_scheduled=null
                    blue_light_filter_type=null
                    blue_light_filter_adaptive_mode=null

                    """
                }
                return samsung.run(script)
            },
            snapshots: makeStore(),
            pause: { _ in }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(samsung.writeCount, 0)
        XCTAssertTrue(filter.needsReconciliation)
    }


    func testUSBReverseIdentitySupportsANetworkADBTransport() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let transport = "192.168.1.8:5555"
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\n\(transport) device model:SM_X800\n" },
            reverseList: { serial in serial == transport ? self.reverseMappingForTests(serial) : nil },
            shell: { _, script in tablet.run(script) },
            snapshots: makeStore(),
            pause: { _ in tablet.settle() }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.panelLevel, 9)
    }

    func testUSBClientBindingRejectsTemporalHotplugSubstitution() {
        let first = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let substitute = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2), serial: "R53")
        var devices = "List of devices attached\nR52 device usb:1-1 model:SM_X800\n"
        let filter = NightShiftTabletFilter(
            listDevices: { devices },
            reverseList: reverseMappingForTests,
            shell: { serial, script in (serial == "R52" ? first : substitute).run(script) },
            snapshots: makeStore(),
            pause: { _ in first.settle(); substitute.settle() }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(first.panelLevel, 9)

        devices = "List of devices attached\nR53 device usb:1-2 model:SM_X800\n"
        filter.show(NightShiftTarget(enabled: true, level: 4))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(substitute.writeCount, 0, "a newly plugged tablet must not inherit the disconnected client's binding")
        XCTAssertTrue(filter.needsReconciliation)
    }

    func testReplacementClientRestoresPreviousTabletBeforeTakingOwnership() {
        let previousOriginal = EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2)
        let previous = FakeSamsungTablet(previousOriginal, serial: "R52")
        let replacement = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2), serial: "R53")
        let devices = """
        List of devices attached
        R52 device usb:1-1 model:SM_X800
        R53 device usb:1-2 model:SM_X800

        """
        var mappedSerial = "R52"
        let store = makeStore()
        let filter = NightShiftTabletFilter(
            listDevices: { devices },
            reverseList: { serial in serial == mappedSerial ? self.reverseMappingForTests(serial) : nil },
            shell: { serial, script in (serial == "R52" ? previous : replacement).run(script) },
            snapshots: store,
            pause: { _ in previous.settle(); replacement.settle() }
        )
        let scope = NightShiftTabletFilter.ClientScope.usb(videoPort: 54321, controlPort: 54322)
        filter.setClientScope(scope)
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(previous.panelLevel, 9)

        mappedSerial = "R53"
        filter.setClientScope(scope)
        filter.show(NightShiftTarget(enabled: true, level: 4))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertEqual(previous.settings, previousOriginal)
        XCTAssertNil(previous.panelLevel)
        XCTAssertNil(store.snapshot(for: "R52"))
        XCTAssertEqual(replacement.panelLevel, 4)
        XCTAssertNotNil(store.snapshot(for: "R53"))
    }

    func testConditionalGraceReleasePreservesTheSamePhysicalReconnect() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let store = makeStore()
        let filter = makeFilter(tablet, store)
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        // A same-device reconnect presents a new endpoint proof, so the binding
        // is reset; grace expiry must still recognize the hardware and skip a
        // flash-inducing restore.
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        filter.releaseDisconnectedClient()
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

        XCTAssertTrue(filter.hasPendingRestores)
        XCTAssertEqual(tablet.panelLevel, 9)
        XCTAssertNotNil(store.snapshot(for: "R52"))
    }

    func testWirelessScopeMatchesOnlyTheNormalizedClientModel() {
        let matching = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let other = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2), serial: "R53")
        let devices = """
        List of devices attached
        192.168.1.8:5555 device model:SM_X800
        192.168.1.9:5555 device model:SM_T970

        """
        let filter = NightShiftTabletFilter(
            listDevices: { devices },
            reverseList: reverseMappingForTests,
            shell: { serial, script in serial.contains("1.8") ? matching.run(script) : other.run(script) },
            snapshots: makeStore(),
            pause: { _ in matching.settle() }
        )
        filter.setClientScope(.wireless(deviceModel: "SM-X800", clientHost: "192.168.1.8"))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(matching.panelLevel, 9)
        XCTAssertEqual(other.writeCount, 0)

        let matchingWrites = matching.writeCount
        filter.setClientScope(.wireless(deviceModel: "SM-S911", clientHost: "192.168.1.8"))
        filter.show(NightShiftTarget(enabled: true, level: 4))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(matching.writeCount, matchingWrites, "a non-matching wireless client must not keep mutating the first tablet")
        XCTAssertEqual(other.writeCount, 0)
    }

    func testWirelessMismatchIsNotTouched() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\n192.168.1.9:5555 device model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: makeStore(),
            pause: { _ in }
        )
        filter.setClientScope(.wireless(deviceModel: "SM-X800", clientHost: "192.168.1.8"))
        filter.show(NightShiftTarget(enabled: true, level: 9))
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertEqual(tablet.writeCount, 0)
        XCTAssertTrue(filter.needsReconciliation)
    }

    func testFailedWriteMarksReconciliationAndASubsequentSuccessClearsIt() {
        let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
        var failWrites = true
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in
                if script == EyeComfortPlan.probeScript { return tablet.run(script) }
                return failWrites ? nil : tablet.run(script)
            },
            snapshots: makeStore(),
            pause: { _ in tablet.settle() }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        let target = NightShiftTarget(enabled: true, level: 9)
        filter.show(target)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertTrue(filter.needsReconciliation)

        failWrites = false
        filter.show(target)
        XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        XCTAssertFalse(filter.needsReconciliation)
        XCTAssertEqual(tablet.panelLevel, 9)
    }


    // MARK: - Mirror lifecycle

    func testMirrorGracePreservesTheSamePhysicalReconnect() async {
        await MainActor.run {
            let tablet = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2), serial: "R52")
            let store = makeStore()
            let filter = makeFilter(tablet, store)
            let reading = NightShiftReading(active: true, automaticScheduleEnabled: true, strength: 0.883, kelvin: 3_028)
            let mirror = NightShiftMirror(
                monitor: NightShiftMonitor(pollS: 60, probe: { reading }),
                filter: filter,
                isEnabled: { true },
                releaseGrace: 0.02
            )
            connectUSB(mirror, generation: 1)
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
            XCTAssertEqual(tablet.panelLevel, 9)

            mirror.clientDisconnected(sessionGeneration: 1)
            connectUSB(mirror, generation: 2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

            XCTAssertEqual(tablet.panelLevel, 9, "same-hardware reconnect must not flash through a restore")
            XCTAssertNotNil(store.snapshot(for: "R52"))
            mirror.releaseNow()
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        }
    }

    func testMirrorGraceHandsBackPreviousTabletWhenReplacementReconnects() async {
        await MainActor.run {
            let previousOriginal = EyeComfortSettings(filter: 0, level: 2, scheduled: 0, type: 2)
            let previous = FakeSamsungTablet(previousOriginal, serial: "R52")
            let replacement = FakeSamsungTablet(EyeComfortSettings(filter: 0, level: 3, scheduled: 0, type: 2), serial: "R53")
            let devices = """
            List of devices attached
            R52 device usb:1-1 model:SM_X800
            R53 device usb:1-2 model:SM_X800

            """
            var mappedSerial = "R52"
            let store = makeStore()
            let filter = NightShiftTabletFilter(
                listDevices: { devices },
                reverseList: { serial in serial == mappedSerial ? self.reverseMappingForTests(serial) : nil },
                shell: { serial, script in (serial == "R52" ? previous : replacement).run(script) },
                snapshots: store,
                pause: { _ in previous.settle(); replacement.settle() }
            )
            let reading = NightShiftReading(active: true, automaticScheduleEnabled: true, strength: 0.883, kelvin: 3_028)
            let mirror = NightShiftMirror(
                monitor: NightShiftMonitor(pollS: 60, probe: { reading }),
                filter: filter,
                isEnabled: { true },
                releaseGrace: 0.02
            )
            connectUSB(mirror, generation: 1)
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
            XCTAssertEqual(previous.panelLevel, 9)

            mirror.clientDisconnected(sessionGeneration: 1)
            mappedSerial = "R53"
            connectUSB(mirror, generation: 2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))

            XCTAssertEqual(previous.settings, previousOriginal)
            XCTAssertNil(previous.panelLevel)
            XCTAssertNil(store.snapshot(for: "R52"))
            XCTAssertEqual(replacement.panelLevel, 9)
            XCTAssertNotNil(store.snapshot(for: "R53"))
            mirror.releaseNow()
            XCTAssertTrue(filter.waitUntilIdle(timeout: 2))
        }
    }

    @MainActor
    private func connectUSB(_ mirror: NightShiftMirror, generation: UInt64) {
        mirror.clientConnected(
            connectionMode: .usb,
            wirelessDeviceModel: nil,
            wirelessClientHost: nil,
            usbVideoPort: 54321,
            usbControlPort: 54322,
            sessionGeneration: generation
        )
    }

    // MARK: - Helpers

    private func reverseMappingForTests(_ serial: String) -> String? {
        "UsbFfs tcp:54321 tcp:54321\nUsbFfs tcp:54322 tcp:54322\n"
    }

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
        let filter = NightShiftTabletFilter(
            listDevices: { "List of devices attached\nR52 device usb:1-1 model:SM_X800\n" },
            reverseList: reverseMappingForTests,
            shell: { _, script in tablet.run(script) },
            snapshots: store,
            pause: { _ in tablet.settle() }
        )
        filter.setClientScope(.usb(videoPort: 54321, controlPort: 54322))
        return filter
    }
}

/// Settings.System plus the observer behavior that decides what the panel
/// shows. Service intents are normally settled after each adb shell round
/// trip; tests can disable that to model Android's real asynchronous
/// `am startservice` delivery explicitly.
private final class FakeSamsungTablet {
    var settings: EyeComfortSettings
    var hasSideTab = true
    var autoSettle = true
    var changeScheduledToZeroAfterOff = false
    let serial: String
    private(set) var panelLevel: Int?
    private(set) var adaptiveActive: Bool
    private(set) var writeCount = 0
    private(set) var offExecutionCount = 0
    private var queuedServiceTypes: [Int] = []

    init(_ settings: EyeComfortSettings, serial: String = "R52") {
        self.settings = settings
        self.serial = serial
        adaptiveActive = (settings.adaptive ?? 0) != 0 && settings.filter != 0
        panelLevel = adaptiveActive ? settings.level : nil
    }

    func run(_ script: String) -> String? {
        if script == EyeComfortPlan.probeScript {
            let s = settings
            let adaptive = s.adaptive.map(String.init) ?? "null"
            return """
            serial=\(serial)
            sidetab=\(hasSideTab ? 1 : 0)
            blue_light_filter=\(s.filter)
            blue_light_filter_opacity=\(s.level)
            blue_light_filter_scheduled=\(s.scheduled)
            blue_light_filter_type=\(s.type)
            blue_light_filter_adaptive_mode=\(adaptive)

            """
        }
        if script == EyeComfortPlan.serviceOffLogCountScript {
            return "\(offExecutionCount)\n"
        }
        for command in script.components(separatedBy: " && ") {
            if command == EyeComfortPlan.serviceScript(EyeComfortPlan.serviceApply) {
                queueService(EyeComfortPlan.serviceApply)
                continue
            }
            if command == EyeComfortPlan.serviceScript(EyeComfortPlan.serviceOff) {
                queueService(EyeComfortPlan.serviceOff)
                continue
            }
            let parts = command.split(separator: " ").map(String.init)
            guard parts.count == 5, parts[0] == "settings", parts[1] == "put",
                  let value = Int(parts[4]) else { return nil }
            switch parts[3] {
            case EyeComfortPlan.keyFilter: settings.filter = value
            case EyeComfortPlan.keyLevel: settings.level = value
            case EyeComfortPlan.keyScheduled: settings.scheduled = value
            case EyeComfortPlan.keyType: settings.type = value
            case EyeComfortPlan.keyAdaptive:
                settings.adaptive = value
                if value != 0, settings.filter != 0 {
                    // The adaptive pipeline is separate from Samsung's Custom
                    // schedule service. Restoring this key is the trigger that
                    // re-arms it after the mirror forced Custom mode.
                    adaptiveActive = true
                    panelLevel = settings.level
                } else if value == 0 {
                    adaptiveActive = false
                    if settings.filter == 0 { panelLevel = nil }
                }
            default: return nil
            }
            writeCount += 1
        }
        if autoSettle { settle() }
        return ""
    }

    private func queueService(_ type: Int) {
        queuedServiceTypes.append(type)
    }

    func settle() {
        let pending = queuedServiceTypes
        queuedServiceTypes.removeAll()
        for type in pending { startService(type) }
    }

    /// BlueLightFilterService.onStartCommand for types 24 and 25. Both are
    /// no-ops unless "Set schedule" is on; schedule types other than Always
    /// on hand off to Samsung's own timer, modeled as "not warm now". Type 24
    /// is deliberately not an Adaptive-mode apply path.
    private func startService(_ type: Int) {
        if type == EyeComfortPlan.serviceOff { offExecutionCount += 1 }
        guard settings.scheduled != 0 else { return }
        if type == EyeComfortPlan.serviceOff {
            panelLevel = nil
            adaptiveActive = false
            if changeScheduledToZeroAfterOff { settings.scheduled = 0 }
        } else if settings.type == EyeComfortPlan.typeAlwaysOn, (settings.adaptive ?? 0) == 0 {
            panelLevel = settings.level
        }
    }
}
