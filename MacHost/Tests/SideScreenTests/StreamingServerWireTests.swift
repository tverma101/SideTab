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

    /// Android builds from before the move to 15 still send decoder limits
    /// under 11. The host accepts that tag inbound so an un-updated tablet does
    /// not desync; it must stay out of the one-tag-per-message table.
    func testLegacyDecoderLimitsTagIsInboundOnly() {
        XCTAssertEqual(WireMessage.legacyClientDecoderLimits, 11)
        XCTAssertNotEqual(WireMessage.legacyClientDecoderLimits, WireMessage.clientDecoderLimits)
        XCTAssertFalse(
            WireMessage.all.filter { $0 == WireMessage.legacyClientDecoderLimits }.count > 1,
            "legacy tag must not be listed alongside bright"
        )
    }

    // MARK: - Decoder limits

    /// The exact bytes a pre-15 Android build sent after tag 11: 8192x8192.
    func testDecoderLimitsDecodeTheLegacyClientPayload() {
        let limits = StreamingServer.decodeClientDecoderLimits([0xC0, 0x80, 0xC0, 0x80])
        XCTAssertEqual(limits?.width, 8_192)
        XCTAssertEqual(limits?.height, 8_192)
    }

    func testDecoderLimitsDecodeSplitsSevenBitHalves() {
        // 3840 = 30 << 7 | 0, 2160 = 16 << 7 | 112; each byte is 0x80 | half.
        let limits = StreamingServer.decodeClientDecoderLimits([0x9E, 0x80, 0x90, 0xF0])
        XCTAssertEqual(limits?.width, 3_840)
        XCTAssertEqual(limits?.height, 2_160)
    }

    func testDecoderLimitsRejectAByteWithoutTheMarkerBit() {
        XCTAssertNil(StreamingServer.decodeClientDecoderLimits([0xC0, 0x00, 0xC0, 0x80]))
        XCTAssertNil(StreamingServer.decodeClientDecoderLimits([0xC0, 0x80, 0xC0]))
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

    // MARK: - Callback identity snapshots

    /// The host fences every MainActor callback on a snapshot read here, on the
    /// server's own queue, at callback-invocation time. It must therefore
    /// report THIS server's identity and the generation the session flags are
    /// currently under — not a value the caller supplies.
    func testSessionSnapshotIdentifiesTheServerThatProducedIt() {
        let server = StreamingServer(port: 54_321)
        let other = StreamingServer(port: 54_322)

        let snapshot = server.currentSessionSnapshot()

        XCTAssertEqual(snapshot.serverID, ObjectIdentifier(server))
        XCTAssertNotEqual(snapshot.serverID, ObjectIdentifier(other))
        XCTAssertFalse(snapshot.live, "a server that never published a session has no live client")
    }

    func testSessionEventMatchesTheSnapshotItWasBuiltFrom() {
        let server = StreamingServer(port: 54_321)

        let snapshot = server.currentSessionSnapshot()
        let event = server.currentSessionEvent()

        XCTAssertEqual(event.serverID, snapshot.serverID)
        XCTAssertEqual(event.sessionGeneration, snapshot.generation)
    }

    func testSessionEventIsEquatableForGateComparison() {
        let server = StreamingServer(port: 54_321)

        XCTAssertEqual(server.currentSessionEvent(), server.currentSessionEvent())
        XCTAssertNotEqual(
            server.currentSessionEvent(),
            StreamingServer(port: 54_321).currentSessionEvent()
        )
    }

    /// Ending a session has to move the generation, including on stop(). The
    /// host revalidates each callback against the server's CURRENT generation
    /// after its main-actor hop, so an event captured before a stop would
    /// otherwise still describe the generation the server appears to hold.
    func testStopAdvancesTheSessionGeneration() {
        let server = StreamingServer(port: 0, controlPort: 0)
        let before = server.currentSessionEvent()

        server.stop()

        XCTAssertNotEqual(before.sessionGeneration, server.currentSessionSnapshot().generation)
        XCTAssertNotEqual(before, server.currentSessionEvent())
        XCTAssertFalse(server.currentSessionSnapshot().live)
    }
}
