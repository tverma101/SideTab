import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import SideScreen

/// A continuation the test opens by hand, modelling a ScreenCaptureKit call
/// that only returns when the test decides it does.
private final class ManualGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var opened = false

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        let pending = continuation
        continuation = nil
        opened = true
        lock.unlock()
        pending?.resume()
    }
}

private enum SampleBufferFactory {
    static func pixelBuffer(width: Int = 32, height: Int = 32) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// A ready sample buffer wrapping an image, which is what a `.complete`
    /// screen frame looks like to the frame handler.
    static func readySampleBuffer() -> CMSampleBuffer? {
        guard let pixelBuffer = pixelBuffer() else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    /// A null buffer — the only shape CoreMedia can report as invalid, and the
    /// shape the frame handler's `isValid` guard exists to survive.
    static func nullSampleBuffer() -> CMSampleBuffer {
        unsafeBitCast(nil as OpaquePointer?, to: CMSampleBuffer.self)
    }
}

final class ScreenCaptureTests: XCTestCase {

    // MARK: - Bounded timeout (SCShareableContent / startCapture / stopCapture)

    func testBoundedTimeoutReturnsCompletedWork() async throws {
        let value = try await ScreenCapture.withBoundedTimeout(
            seconds: 5,
            description: "test-immediate"
        ) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testBoundedTimeoutPropagatesWorkFailure() async {
        struct Boom: Error {}
        do {
            _ = try await ScreenCapture.withBoundedTimeout(
                seconds: 5,
                description: "test-failure"
            ) {
                throw Boom()
            }
            XCTFail("expected the operation error to propagate")
        } catch is Boom {
            // pass
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The regression this guards: a hung SCShareableContent must not keep the
    /// caller's await suspended, because nothing can cancel a hung XPC call.
    func testBoundedTimeoutUnblocksWhenWorkHangs() async throws {
        let gate = ManualGate()
        let started = Date()
        do {
            _ = try await ScreenCapture.withBoundedTimeout(
                seconds: 0.2,
                description: "test-hang"
            ) {
                try await gate.wait()
                return 1
            }
            XCTFail("expected the timeout to fire")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ScreenCapture")
            XCTAssertEqual(nsError.code, 10)
            XCTAssertTrue(nsError.localizedDescription.contains("test-hang timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0, "await must not wait on the hung work")

        // The work lands after the timeout already resumed the caller; it must
        // be dropped, not resumed again (a double resume traps with
        // SWIFT TASK CONTINUATION MISUSE).
        gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Encode backpressure

    func testBackpressureAdmitsUpToTheLimit() {
        let backpressure = EncodeBackpressure()
        XCTAssertTrue(backpressure.admit())
        XCTAssertTrue(backpressure.admit())
        XCTAssertFalse(backpressure.admit(), "3 concurrent encodes must be refused")
        backpressure.release()
        XCTAssertTrue(backpressure.admit())
    }

    func testStaleDrainFromAnOlderSessionCannotDisableTheNewGate() {
        let oldSession = EncodeBackpressure()
        XCTAssertTrue(oldSession.admit())

        // The new session's queue starts while the old one's blocks are still
        // draining. Those drains decrement the old counter only — sharing one
        // counter is what used to let it go negative and admit every frame.
        let newSession = EncodeBackpressure()
        oldSession.release()
        oldSession.release()
        XCTAssertLessThan(oldSession.count, 0)
        XCTAssertEqual(newSession.count, 0)
        XCTAssertTrue(newSession.admit())
        XCTAssertTrue(newSession.admit())
        XCTAssertFalse(newSession.admit())
    }

    func testBackpressureFailsClosedOnANegativeCount() {
        let backpressure = EncodeBackpressure()
        XCTAssertTrue(backpressure.admit())
        // One release too many — how the old shared counter went negative and
        // silently switched backpressure off for the rest of the session.
        backpressure.release()
        backpressure.release()
        XCTAssertLessThan(backpressure.count, 0)
        XCTAssertFalse(backpressure.admit(), "a negative count must fail closed")

        // The next session gets its own gate, so the debt cannot outlive it.
        let nextSession = EncodeBackpressure()
        XCTAssertEqual(nextSession.count, 0)
        XCTAssertTrue(nextSession.admit())
    }

    // MARK: - StreamOutput gating

    func testStreamOutputDropsInvalidAndNonScreenBuffers() throws {
        let ready = try XCTUnwrap(SampleBufferFactory.readySampleBuffer())
        XCTAssertTrue(ready.isValid)
        XCTAssertTrue(StreamOutput.shouldDeliver(type: .screen, sampleBuffer: ready))
        XCTAssertFalse(StreamOutput.shouldDeliver(type: .audio, sampleBuffer: ready))

        let invalid = SampleBufferFactory.nullSampleBuffer()
        XCTAssertFalse(
            StreamOutput.shouldDeliver(type: .screen, sampleBuffer: invalid),
            "an invalid screen buffer has no pixels to decode"
        )
    }

    // MARK: - Session fences

    func testIdlePauseRequiresALiveStream() async throws {
        let capture = try await ScreenCapture()
        capture.pauseForIdle()
        XCTAssertFalse(capture.idlePaused, "pause must not latch with no live stream")
        capture.resumeFromIdle()
        XCTAssertFalse(capture.idlePaused)
    }

    func testStopIsIdempotentWithoutASession() async throws {
        let capture = try await ScreenCapture()
        capture.stopStreaming()
        capture.stopStreaming()
        capture.pauseForIdle()
        capture.resumeFromIdle()
        XCTAssertFalse(capture.idlePaused)
    }
}
