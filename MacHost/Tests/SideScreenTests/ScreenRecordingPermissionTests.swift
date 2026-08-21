import XCTest
@testable import SideScreen

final class ScreenRecordingPermissionTests: XCTestCase {
    func testDeniedSnapshotIdentifiesCurrentBundleAndRecovery() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: false,
            bundleIdentifier: "com.sidescreen.app",
            bundleName: "Side Screen",
            bundlePath: "/Users/redacted/Applications/SideScreen.app",
            canonicalInstallPath: "/Users/redacted/Applications/SideScreen.app"
        )

        XCTAssertEqual(snapshot.statusText, "Required for this build")
        XCTAssertTrue(snapshot.isCanonicalInstall)
        XCTAssertTrue(snapshot.diagnosticText.contains("exact running bundle"))
        XCTAssertTrue(snapshot.recoveryText.contains("remove the entry"))
        XCTAssertTrue(snapshot.identityText.contains("com.sidescreen.app"))
    }

    func testNonCanonicalSnapshotPointsAtCanonicalInstall() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: false,
            bundleIdentifier: "com.sidescreen.app",
            bundleName: "Side Screen",
            bundlePath: "/tmp/SideScreen.app",
            canonicalInstallPath: "/Users/redacted/Applications/SideScreen.app"
        )

        XCTAssertFalse(snapshot.isCanonicalInstall)
        XCTAssertTrue(snapshot.recoveryText.contains("canonical installed copy"))
    }

    func testGrantedSnapshotUsesBuildSpecificStatus() {
        let snapshot = ScreenRecordingPermissionSnapshot(
            isGranted: true,
            bundleIdentifier: "com.sidescreen.app",
            bundleName: "Side Screen",
            bundlePath: "/Users/redacted/Applications/SideScreen.app",
            canonicalInstallPath: "/Users/redacted/Applications/SideScreen.app"
        )

        XCTAssertEqual(snapshot.statusText, "Granted for this build")
        XCTAssertTrue(snapshot.diagnosticText.contains("accepted"))
    }
}
