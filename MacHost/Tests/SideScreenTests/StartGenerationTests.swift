import XCTest
@testable import SideScreen

final class StartGenerationTests: XCTestCase {
    func testSecondStartIsRejectedWhileOneIsInFlight() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())

        XCTAssertTrue(generation.hasInFlightStart)
        XCTAssertNil(generation.begin(), "a double Start must not build a second display/server")
    }

    func testFinishReleasesTheLatchSynchronously() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())
        generation.finish(token)

        XCTAssertFalse(generation.hasInFlightStart)
        XCTAssertNotNil(generation.begin())
    }

    func testFinishFromAStaleTokenDoesNotReleaseTheCurrentLatch() throws {
        let generation = StartGeneration()
        let first = try XCTUnwrap(generation.begin())
        generation.cancel()
        let second = try XCTUnwrap(generation.begin())

        generation.finish(first)

        XCTAssertTrue(generation.hasInFlightStart, "a rolled-back attempt must not free a newer start's latch")
        XCTAssertTrue(generation.isCurrent(second))
    }

    /// Cmd-Q during the ~55 s display-creation window: stopServer() cancels, and
    /// the suspended start must notice at its next check instead of resurrecting
    /// the display, server, capture pipeline and idle-sleep assertion.
    func testCancelInvalidatesAnInFlightStartAndFreesTheLatch() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())

        generation.cancel()

        XCTAssertFalse(generation.isCurrent(token))
        XCTAssertFalse(generation.hasInFlightStart, "the next Start click must be accepted immediately")
        XCTAssertNotNil(generation.begin())
    }

    func testTokensAreUniqueAndNeverRepeat() throws {
        let generation = StartGeneration()
        var seen: Set<UInt64> = []
        for _ in 0..<64 {
            let token = try XCTUnwrap(generation.begin())
            XCTAssertTrue(seen.insert(token.value).inserted, "a token must never be handed out twice")
            generation.cancel()
        }
        XCTAssertEqual(seen.count, 64)
    }

    func testIsCurrentIsFalseForAForeignToken() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())
        XCTAssertTrue(generation.isCurrent(token))
        XCTAssertFalse(generation.isCurrent(StartGeneration.Token(value: token.value - 1)))
    }

    /// A start that is only cancelled still owns the state its own rollback
    /// resets: the app really is stopped, so it must report "not running".
    func testCancelAloneDoesNotSupersedeTheAttempt() throws {
        let generation = StartGeneration()
        let token = try XCTUnwrap(generation.begin())
        generation.cancel()
        XCTAssertFalse(generation.isSuperseded(token))
    }

    /// stop → immediate re-Start → the first attempt resumes late: it must tear
    /// down only its own objects and must not report the live session stopped.
    func testNewerAttemptSupersedesAnOlderOne() throws {
        let generation = StartGeneration()
        let first = try XCTUnwrap(generation.begin())
        generation.cancel()
        let second = try XCTUnwrap(generation.begin())
        XCTAssertTrue(generation.isSuperseded(first))
        XCTAssertFalse(generation.isSuperseded(second))
    }
}

final class BackgroundProbeWatchdogTests: XCTestCase {
    func testMissingStartTimeIsNeverStale() {
        XCTAssertFalse(BackgroundProbeWatchdog.isStale(startedAt: nil, now: Date()))
    }

    func testFreshProbeIsNotStale() {
        let now = Date()
        let started = now.addingTimeInterval(-BackgroundProbeWatchdog.defaultStaleAfter + 1)
        XCTAssertFalse(BackgroundProbeWatchdog.isStale(startedAt: started, now: now))
    }

    func testHungProbeGoesStale() {
        let now = Date()
        let started = now.addingTimeInterval(-BackgroundProbeWatchdog.defaultStaleAfter - 1)
        XCTAssertTrue(BackgroundProbeWatchdog.isStale(startedAt: started, now: now))
    }

    func testDeadlineCoversThreeSequentialAdbCalls() {
        // Worst case per refresh: adb path lookup, `adb devices`, one
        // `adb reverse --list` (the two port checks share one cached process).
        XCTAssertGreaterThan(
            BackgroundProbeWatchdog.defaultStaleAfter,
            ADBCommandRunner.defaultTimeout * 3
        )
    }
}

final class DisplayTransformStoreTests: XCTestCase {
    func testSnapshotStartsAtIdentity() {
        let store = DisplayTransformStore()
        XCTAssertEqual(
            store.snapshot,
            DisplayTransformStore.Transform(rotation: 0, flipHorizontal: false, flipVertical: false)
        )
    }

    func testUpdateIsVisibleToTheNextSnapshot() {
        let store = DisplayTransformStore()
        store.update(rotation: 90, flipHorizontal: true, flipVertical: false)
        XCTAssertEqual(
            store.snapshot,
            DisplayTransformStore.Transform(rotation: 90, flipHorizontal: true, flipVertical: false)
        )
    }

    func testConcurrentWritersNeverPublishATornSnapshot() {
        let store = DisplayTransformStore()
        let group = DispatchGroup()
        for index in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                store.update(
                    rotation: index,
                    flipHorizontal: index.isMultiple(of: 2),
                    flipVertical: index.isMultiple(of: 3)
                )
                let snapshot = store.snapshot
                XCTAssertTrue((0..<200).contains(snapshot.rotation))
                group.leave()
            }
        }
        group.wait()
    }
}
