import XCTest
@testable import SideScreen

/// `swift test` exercises code that calls debugLog, and it runs as the same
/// user as the installed host. These pin that a test run never writes the live
/// host's log, which is the file read as evidence when a tablet misbehaves.
final class AsyncDebugLoggerTests: XCTestCase {
    func testLongRunningLoggerRotatesWithoutReopeningTheProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideScreenLogRotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AsyncDebugLogger(directoryURL: directory, maxLogBytes: 180)

        // Flush each batch to model sustained logging in one login session.
        // The previous implementation kept the same open file forever.
        for generation in 0..<20 {
            logger.log("rotation marker \(generation): " + String(repeating: "x", count: 80))
            logger.flush()
        }

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["sidescreen.log", "sidescreen.log.1", "sidescreen.log.2"])
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 180)
        }
        XCTAssertTrue(try String(contentsOf: logger.logURL, encoding: .utf8).contains("rotation marker 19:"))
        XCTAssertTrue(try String(contentsOf: logger.logURL.appendingPathExtension("2"), encoding: .utf8).contains("rotation marker 17:"))
    }

    func testUnavailableLogDirectoryDoesNotBlockOrCrashLogging() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("SideScreenLogFailure-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let logger = AsyncDebugLogger(directoryURL: parent.appendingPathComponent("Logs"), maxLogBytes: 100)
        for _ in 0..<3 {
            logger.log("storage unavailable")
            logger.flush()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.logURL.path))
    }

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
