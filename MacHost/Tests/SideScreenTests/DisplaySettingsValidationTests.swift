import XCTest
@testable import SideScreen

/// Every persisted numeric is user-writable through `defaults`, and the
/// settings model is constructed on the main thread while AppDelegate's
/// properties are still being set up. A value the panel cannot represent — or
/// one that traps on conversion — used to kill launch with no window, no menu
/// bar and no dialog.
final class DisplaySettingsValidationTests: XCTestCase {
    private let keys = [
        "SideScreen_port", "SideScreen_refreshRate", "SideScreen_bitrate",
        "SideScreen_rotation", "SideScreen_connectionMode", "SideScreen_startupMode",
    ]

    override func tearDown() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testPortAboveUInt16MaxDoesNotTrapLaunch() {
        UserDefaults.standard.set(100_000, forKey: "SideScreen_port")
        let settings = DisplaySettings()
        XCTAssertEqual(settings.port, UInt16.max)
    }

    func testNegativePortIsClampedInsteadOfTrapping() {
        UserDefaults.standard.set(-1, forKey: "SideScreen_port")
        let settings = DisplaySettings()
        XCTAssertEqual(settings.port, 1)
    }

    func testOutOfDomainBitrateAndRefreshRateAreClampedOnLoad() {
        UserDefaults.standard.set(6000, forKey: "SideScreen_bitrate")
        UserDefaults.standard.set(0, forKey: "SideScreen_refreshRate")
        let settings = DisplaySettings()
        XCTAssertEqual(settings.bitrate, 5000)
        XCTAssertTrue(DisplaySettings.refreshRateChoices.contains(settings.refreshRate))
    }

    func testRotationSnapsToAKnownTransformOnLoad() {
        UserDefaults.standard.set(45, forKey: "SideScreen_rotation")
        XCTAssertTrue(DisplaySettings.rotationChoices.contains(DisplaySettings().rotation))

        UserDefaults.standard.set(-90, forKey: "SideScreen_rotation")
        XCTAssertEqual(DisplaySettings().rotation, 270)
    }

    func testNonNumericValuesFallBackToDefaults() {
        UserDefaults.standard.set("nonsense", forKey: "SideScreen_port")
        UserDefaults.standard.set("nonsense", forKey: "SideScreen_refreshRate")
        let settings = DisplaySettings()
        XCTAssertEqual(settings.port, DisplaySettings.defaultPort)
        XCTAssertEqual(settings.refreshRate, DisplaySettings.defaultRefreshRate)
    }

    func testWritesAreValidatedToo() {
        let settings = DisplaySettings()
        // port is a UInt16, so only the low end is reachable from code; the high
        // end is what a hand-edited plist can produce, and that is covered above.
        settings.port = 0
        XCTAssertEqual(settings.port, 1)
        settings.bitrate = -1
        XCTAssertEqual(settings.bitrate, 20)
        settings.refreshRate = 0
        XCTAssertEqual(settings.refreshRate, 30)
        settings.rotation = -90
        XCTAssertEqual(settings.rotation, 270)
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: "SideScreen_rotation"), 270,
            "the sanitised value must be the one persisted"
        )
    }

    func testSanitizersMatchThePanelDomain() {
        XCTAssertEqual(DisplaySettings.sanitizedPort(70_000), UInt16.max)
        XCTAssertEqual(DisplaySettings.sanitizedPort(0), 1)
        XCTAssertEqual(DisplaySettings.sanitizedPort(-5), 1)
        XCTAssertEqual(DisplaySettings.sanitizedPort(54321), 54321)

        XCTAssertEqual(DisplaySettings.sanitizedBitrate(6000), 5000)
        XCTAssertEqual(DisplaySettings.sanitizedBitrate(19), 20)
        XCTAssertEqual(DisplaySettings.sanitizedBitrate(1000), 1000)

        for raw in [-1, 0, 45, 200, 1000] {
            XCTAssertTrue(
                DisplaySettings.refreshRateChoices.contains(DisplaySettings.sanitizedRefreshRate(raw)),
                "refresh rate \(raw)"
            )
        }
        for raw in [-90, -360, 0, 45, 91, 180, 269, 270, 359, 360, 450, 100_000] {
            XCTAssertTrue(
                DisplaySettings.rotationChoices.contains(DisplaySettings.sanitizedRotation(raw)),
                "rotation \(raw)"
            )
        }
        XCTAssertEqual(DisplaySettings.sanitizedRotation(359), 0)
        XCTAssertEqual(DisplaySettings.sanitizedRotation(360), 0)
        XCTAssertEqual(DisplaySettings.sanitizedRotation(-90), 270)
    }

    /// The reset path and a fresh install must land on the same values, and the
    /// alert promises the connection mode goes back to its default too.
    func testResetToDefaultsMatchesAFreshInstall() {
        UserDefaults.standard.set(0, forKey: "SideScreen_connectionMode")
        let settings = DisplaySettings()
        XCTAssertEqual(settings.refreshRate, DisplaySettings.defaultRefreshRate)
        XCTAssertEqual(settings.bitrate, DisplaySettings.defaultBitrate)
        XCTAssertEqual(settings.quality, DisplaySettings.defaultQuality)
        XCTAssertEqual(settings.port, DisplaySettings.defaultPort)

        settings.refreshRate = 120
        settings.bitrate = 2000
        settings.quality = "max"
        settings.port = 9000
        settings.rotation = 180
        settings.connectionMode = .wireless
        settings.resetToDefaults()

        XCTAssertEqual(settings.refreshRate, DisplaySettings.defaultRefreshRate)
        XCTAssertEqual(settings.bitrate, DisplaySettings.defaultBitrate)
        XCTAssertEqual(settings.quality, DisplaySettings.defaultQuality)
        XCTAssertEqual(settings.port, DisplaySettings.defaultPort)
        XCTAssertEqual(settings.rotation, 0)
        XCTAssertEqual(settings.connectionMode, .usb)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "SideScreen_connectionMode"), "usb")
    }

    /// The rotation sink publishes an atomic triple, so an off-main reader
    /// cannot pair a new rotation with a stale flip.
    func testTransformSnapshotTracksTheTransform() {
        let settings = DisplaySettings()
        XCTAssertEqual(settings.transformSnapshot.rotation, 0)
        settings.rotation = 90
        settings.flipHorizontal = true
        let snapshot = settings.transformSnapshot
        XCTAssertEqual(snapshot.rotation, 90)
        XCTAssertTrue(snapshot.flipHorizontal)
        XCTAssertFalse(snapshot.flipVertical)
        XCTAssertEqual(settings.resolutionSize.width, 876)
        XCTAssertEqual(settings.resolutionSize.height, 1400)
    }
}
