import XCTest
@testable import SideScreen

/// The adb runner is the only thing standing between a wedged adb and a
/// permanently bricked start button, so both of the `waitUntilExit()` traps are
/// covered here: a child that outgrows the 64 KB pipe buffer, and a child that
/// never exits at all.
final class ADBCommandRunnerTests: XCTestCase {
    func testReturnsOutputAndSuccessForFastChild() throws {
        let result = try XCTUnwrap(ADBCommandRunner.run("/bin/echo", arguments: ["device-1 device usb:0-1"]))
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "device-1 device usb:0-1")
    }

    func testReportsNonZeroExitWithoutHidingOutput() throws {
        let result = try XCTUnwrap(ADBCommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo 'error: no devices/emulators found' >&2; exit 1"]
        ))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("no devices/emulators found"))
    }

    /// Reading the pipe only after waitUntilExit() deadlocks here: `yes` writes
    /// far more than the 64 KB pipe buffer before it exits.
    func testDrainsOutputLargerThanThePipeBuffer() throws {
        let result = try XCTUnwrap(ADBCommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "yes abcdefgh | head -c 400000"],
            timeout: 20
        ))
        XCTAssertTrue(result.succeeded, "child wrote 400 KB and must not have blocked on a full buffer")
        XCTAssertGreaterThanOrEqual(result.output.utf8.count, 400_000)
    }

    func testTerminatesAChildThatNeverExits() throws {
        let started = Date()
        let result = try XCTUnwrap(ADBCommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 60"],
            timeout: 1
        ))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed, 15, "a hung adb must not hold the caller for the life of the child")
    }

    func testTerminatesAChildThatIgnoresSigterm() throws {
        let result = try XCTUnwrap(ADBCommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 60"],
            timeout: 1
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testUnspawnableExecutableReportsNil() {
        XCTAssertNil(ADBCommandRunner.run("/nonexistent/adb", arguments: ["devices"]))
    }

    func testDefaultTimeoutIsBounded() {
        XCTAssertGreaterThan(ADBCommandRunner.defaultTimeout, 0)
        XCTAssertLessThanOrEqual(
            ADBCommandRunner.defaultTimeout,
            ADBCommandRunner.shortLookupTimeout * 4
        )
    }
}
