import XCTest
@testable import SideScreen

/// `swift test` exercises code that calls debugLog, and it runs as the same
/// user as the installed host. These pin that a test run never writes the live
/// host's log, which is the file read as evidence when a tablet misbehaves.
final class AsyncDebugLoggerTests: XCTestCase {
    func testLiveHostLogsUnderLibraryLogs() {
        let live = AsyncDebugLogger.logDirectory(isTestProcess: false)
        XCTAssertTrue(live.path.hasSuffix("/Library/Logs/SideScreen"), live.path)
    }

    func testTestProcessUsesAScratchLogDirectory() {
        XCTAssertTrue(AsyncDebugLogger.isTestProcess)
        let live = AsyncDebugLogger.logDirectory(isTestProcess: false).standardizedFileURL.path
        let used = AsyncDebugLogger.shared.logURL.deletingLastPathComponent().standardizedFileURL.path
        XCTAssertNotEqual(used, live)
        XCTAssertFalse(used.hasPrefix(live + "/"), used)
    }

    func testDebugLogLinesLandInTheTestLogOnly() throws {
        let marker = "AsyncDebugLoggerTests marker \(UUID().uuidString)"
        debugLog(marker)

        let testLog = AsyncDebugLogger.shared.logURL
        let deadline = Date().addingTimeInterval(5)
        var written = false
        while !written && Date() < deadline {
            written = (try? String(contentsOf: testLog, encoding: .utf8))?.contains(marker) == true
            if !written { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(written, "marker never reached \(testLog.path)")

        let liveLog = AsyncDebugLogger.logDirectory(isTestProcess: false)
            .appendingPathComponent("sidescreen.log")
        let live = (try? String(contentsOf: liveLog, encoding: .utf8)) ?? ""
        XCTAssertFalse(live.contains(marker), "a test run wrote the live host log")
    }
}
