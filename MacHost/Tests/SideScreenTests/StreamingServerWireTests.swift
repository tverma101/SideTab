import Foundation
import XCTest
@testable import SideScreen

/// Covers the parts of the host↔client wire contract that are pure data:
/// tag uniqueness, display-config validation, frame-size limits, and control
/// port resolution. Nothing here opens a socket.
final class StreamingServerWireTests: XCTestCase {
    // MARK: - Tag table

    /// Two messages sharing one tag value cannot be told apart by a client that
    /// dispatches on the tag alone — it used to be 11 for both `bright` and
    /// `clientDecoderLimits`, and the "a byte-at-a-time skipper eats the payload
    /// harmlessly" reasoning behind it desyncs the stream by 4 bytes instead.
    func testEveryWireTagIsUnique() {
        XCTAssertEqual(
            Set(WireMessage.all).count,
            WireMessage.all.count,
            "duplicate wire tag: two messages would share one wire type"
        )
    }

    func testTagTableCoversTheKnownProtocol() {
        XCTAssertEqual(WireMessage.legacyVideoFrame, 0)
        XCTAssertEqual(WireMessage.displayConfig, 1)
        XCTAssertEqual(WireMessage.touchEvent, 2)
        XCTAssertEqual(WireMessage.clientSupportsBrightness, 3)
        XCTAssertEqual(WireMessage.ping, 4)
        XCTAssertEqual(WireMessage.pong, 5)
        XCTAssertEqual(WireMessage.videoFrameWithMetadata, 6)
        XCTAssertEqual(WireMessage.keyframeRequest, 7)
        XCTAssertEqual(WireMessage.clientSupportsFrameMetadata, 8)
        XCTAssertEqual(WireMessage.clientAvcOnly, 9)
        XCTAssertEqual(WireMessage.codecSelected, 10)
        XCTAssertEqual(WireMessage.bright, 11)
        XCTAssertEqual(WireMessage.clientSupportsStylus, 12)
        XCTAssertEqual(WireMessage.serverSupportsStylus, 13)
        XCTAssertEqual(WireMessage.stylusEvent, 14)
        XCTAssertEqual(WireMessage.clientDecoderLimits, 15)
    }

    // MARK: - Display config

    /// The client's DisplayConfig.fromWire throws — and the client treats it as
    /// a fatal protocol error, reconnecting forever — for any rotation outside
    /// {0,90,180,270} or dimension outside 1...16384.
    func testRotationSnapsToTheClientQuadrantSet() {
        XCTAssertEqual(StreamingServer.normalizedRotation(0), 0)
        XCTAssertEqual(StreamingServer.normalizedRotation(90), 90)
        XCTAssertEqual(StreamingServer.normalizedRotation(180), 180)
        XCTAssertEqual(StreamingServer.normalizedRotation(270), 270)
        XCTAssertEqual(StreamingServer.normalizedRotation(360), 0)
        XCTAssertEqual(StreamingServer.normalizedRotation(-90), 270)
        XCTAssertEqual(StreamingServer.normalizedRotation(45), 90)
        XCTAssertEqual(StreamingServer.normalizedRotation(300), 270)
    }

    func testAnyRotationLandsInsideTheClientQuadrantSet() {
        for raw in stride(from: -1_000, through: 1_000, by: 7) {
            let normalized = StreamingServer.normalizedRotation(raw)
            XCTAssertTrue([0, 90, 180, 270].contains(normalized), "rotation \(raw) -> \(normalized)")
            XCTAssertEqual(normalized, StreamingServer.normalizedRotation(raw + 360))
        }
        // Far past the 1000 flag field: a raw value must never leak a
        // transform%1000 the client rejects.
        XCTAssertTrue([0, 90, 180, 270].contains(StreamingServer.normalizedRotation(1_000_003)))
    }

    func testDimensionsClampIntoTheClientAcceptedRange() {
        XCTAssertEqual(StreamingServer.clampedDisplaySize(width: 2_800, height: 1_752).width, 2_800)
        XCTAssertEqual(StreamingServer.clampedDisplaySize(width: 0, height: -5).width, 1)
        XCTAssertEqual(StreamingServer.clampedDisplaySize(width: 0, height: -5).height, 1)
        XCTAssertEqual(StreamingServer.clampedDisplaySize(width: 99_999, height: 10).width, 16_384)
    }

    func testOversizedPixelCountIsScaledUnderTheClientCeiling() {
        let size = StreamingServer.clampedDisplaySize(width: 16_384, height: 16_384)
        XCTAssertLessThanOrEqual(Int64(size.width) * Int64(size.height), StreamingServer.maxWirePixels)
        XCTAssertGreaterThanOrEqual(size.width, 1)
        XCTAssertGreaterThanOrEqual(size.height, 1)
    }

    func testDisplayConfigPayloadIsAlwaysClientParsable() {
        let payload = StreamingServer.displayConfigPayload(
            width: 99_999,
            height: -1,
            rotation: 1_234,
            flipHorizontal: true,
            flipVertical: true
        )
        XCTAssertEqual(payload.count, 13)
        XCTAssertEqual(payload.first, WireMessage.displayConfig)

        let width = Int(beInt32(payload, at: 1))
        let height = Int(beInt32(payload, at: 5))
        let transform = Int(beInt32(payload, at: 9))
        XCTAssertTrue((1...16_384).contains(width))
        XCTAssertTrue((1...16_384).contains(height))
        XCTAssertTrue([0, 90, 180, 270].contains(transform % 1_000))
        XCTAssertTrue((0...3).contains(transform / 1_000))
    }

    func testFlipFlagsLandInTheClientFlagRange() {
        for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] {
            let payload = StreamingServer.displayConfigPayload(
                width: 1_920,
                height: 1_080,
                rotation: 90,
                flipHorizontal: horizontal,
                flipVertical: vertical
            )
            let transform = Int(beInt32(payload, at: 9))
            XCTAssertTrue((0...3).contains(transform / 1_000), "flags \(transform / 1_000)")
            XCTAssertEqual(transform % 1_000, 90)
        }
    }

    private func beInt32(_ data: Data, at offset: Int) -> Int32 {
        data.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
    }

    // MARK: - Frame size

    func testFrameSizeIsClampedToTheClientLimit() {
        XCTAssertEqual(StreamingServer.wireFrameSize(1), 1)
        XCTAssertEqual(StreamingServer.wireFrameSize(5 * 1024 * 1024), 5 * 1024 * 1024)
        // MAX_FRAME_SIZE + 1 is what the client rejects with an IOException.
        XCTAssertNil(StreamingServer.wireFrameSize(5 * 1024 * 1024 + 1))
        XCTAssertNil(StreamingServer.wireFrameSize(0))
        XCTAssertNil(StreamingServer.wireFrameSize(Int.max))
    }

    // MARK: - Control port

    func testControlPortOverrideRejectsPrivilegedAndCollidingPorts() {
        let defaults = UserDefaults(suiteName: "StreamingServerWireTests")!
        defer { defaults.removePersistentDomain(forName: "StreamingServerWireTests") }

        defaults.set(1_023, forKey: ControlPortResolver.defaultsKey)
        XCTAssertNil(ControlPortResolver.explicitOverride(videoPort: 54_321, defaults: defaults))
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54_321, defaults: defaults), 54_322)

        defaults.set(80, forKey: ControlPortResolver.defaultsKey)
        XCTAssertNil(ControlPortResolver.explicitOverride(videoPort: 54_321, defaults: defaults))

        defaults.set(54_321, forKey: ControlPortResolver.defaultsKey)
        XCTAssertNil(ControlPortResolver.explicitOverride(videoPort: 54_321, defaults: defaults))
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54_321, defaults: defaults), 54_322)

        defaults.set(1_024, forKey: ControlPortResolver.defaultsKey)
        XCTAssertEqual(ControlPortResolver.explicitOverride(videoPort: 54_321, defaults: defaults), 1_024)

        defaults.set(65_536, forKey: ControlPortResolver.defaultsKey)
        XCTAssertNil(ControlPortResolver.explicitOverride(videoPort: 54_321, defaults: defaults))
    }

    func testServerWithoutOverrideUsesTheResolverPairing() {
        let server = StreamingServer(port: 54_321)
        XCTAssertEqual(server.controlPortNumber, 54_322)
    }

    func testExplicitControlPortIsPreserved() {
        let server = StreamingServer(port: 54_321, controlPort: 55_123)
        XCTAssertEqual(server.controlPortNumber, 55_123)
    }
}
