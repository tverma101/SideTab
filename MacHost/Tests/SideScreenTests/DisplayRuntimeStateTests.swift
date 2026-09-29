import Combine
import XCTest
@testable import SideScreen

final class DisplayRuntimeStateTests: XCTestCase {
    func testPerformanceMetricUpdatesDoNotPublishRuntimeStateChanges() {
        let runtime = DisplayRuntimeState()
        let performance = DisplayPerformanceState()
        var runtimeChanges = 0
        var performanceChanges = 0

        let runtimeCancellable = runtime.objectWillChange.sink { _ in
            runtimeChanges += 1
        }
        let performanceCancellable = performance.objectWillChange.sink { _ in
            performanceChanges += 1
        }

        performance.currentFPS = 60
        performance.currentBitrate = 42

        withExtendedLifetime((runtimeCancellable, performanceCancellable)) {
            XCTAssertEqual(runtimeChanges, 0)
            XCTAssertGreaterThan(performanceChanges, 0)
            XCTAssertEqual(performance.currentFPS, 60)
            XCTAssertEqual(performance.currentBitrate, 42)
        }
    }

    func testRuntimeStateUpdatesDoNotPublishPerformanceMetricChanges() {
        let runtime = DisplayRuntimeState()
        let performance = DisplayPerformanceState()
        var runtimeChanges = 0
        var performanceChanges = 0

        let runtimeCancellable = runtime.objectWillChange.sink { _ in
            runtimeChanges += 1
        }
        let performanceCancellable = performance.objectWillChange.sink { _ in
            performanceChanges += 1
        }

        runtime.clientConnected = true
        runtime.isRunning = true

        withExtendedLifetime((runtimeCancellable, performanceCancellable)) {
            XCTAssertGreaterThan(runtimeChanges, 0)
            XCTAssertEqual(performanceChanges, 0)
            XCTAssertTrue(runtime.clientConnected)
            XCTAssertTrue(runtime.isRunning)
            XCTAssertEqual(performance.currentFPS, 0)
            XCTAssertEqual(performance.currentBitrate, 0)
        }
    }
}
