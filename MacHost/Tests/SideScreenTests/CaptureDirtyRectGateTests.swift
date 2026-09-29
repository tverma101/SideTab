import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest
@testable import SideScreen

final class CaptureDirtyRectGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CaptureDirtyRectGate.resetTelemetry()
    }

    func testSkipsOnlyExplicitlyCleanFrames() {
        XCTAssertTrue(
            CaptureDirtyRectGate.shouldSkip(
                frameHasChanges: false,
                mutatesCapturedPixels: false
            )
        )
        XCTAssertFalse(
            CaptureDirtyRectGate.shouldSkip(
                frameHasChanges: true,
                mutatesCapturedPixels: false
            )
        )
        XCTAssertFalse(
            CaptureDirtyRectGate.shouldSkip(
                frameHasChanges: nil,
                mutatesCapturedPixels: false
            )
        )
    }

    func testNeverSkipsSyntheticPixelMutation() {
        XCTAssertFalse(
            CaptureDirtyRectGate.shouldSkip(
                frameHasChanges: false,
                mutatesCapturedPixels: true
            )
        )
    }

    /// The real SCStreamFrameInfoDirtyRects attachment: a CFArray of
    /// CFDictionary rects. Neither `as? [CGRect]` nor `as? [NSValue]` can see
    /// that representation, so while it went undecoded the gate answered nil
    /// for EVERY frame and the dirty-rect optimization saved nothing.
    func testDecodesRealDictionaryRepresentation() throws {
        let sample = try makeSampleBuffer(dirtyRects: dictionaryArray([CGRect(x: 10, y: 20, width: 30, height: 40)]))
        XCTAssertEqual(CaptureDirtyRectGate.frameHasChanges(sample), true)
        XCTAssertEqual(CaptureDirtyRectGate.unknownRepresentationCount, 0)
    }

    func testEmptyDictionaryRepresentationIsAnExplicitNoChange() throws {
        let sample = try makeSampleBuffer(dirtyRects: dictionaryArray([]))
        let verdict = CaptureDirtyRectGate.frameHasChanges(sample)
        XCTAssertEqual(verdict, false)
        XCTAssertTrue(CaptureDirtyRectGate.shouldSkip(frameHasChanges: verdict, mutatesCapturedPixels: false))
    }

    func testDictionaryRepresentationWithNullRectIsAnExplicitNoChange() throws {
        let sample = try makeSampleBuffer(dirtyRects: dictionaryArray([CGRect.null]))
        XCTAssertEqual(CaptureDirtyRectGate.frameHasChanges(sample), false)
    }

    func testDictionaryRepresentationSpanningManyRectsIsAChange() throws {
        let sample = try makeSampleBuffer(dirtyRects: dictionaryArray([
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 5, y: 6, width: 7, height: 8)
        ]))
        XCTAssertEqual(CaptureDirtyRectGate.frameHasChanges(sample), true)
    }

    func testPlainCGRectArrayStillDecodes() throws {
        let sample = try makeSampleBuffer(dirtyRects: [CGRect(x: 1, y: 2, width: 3, height: 4)] as CFArray)
        XCTAssertEqual(CaptureDirtyRectGate.frameHasChanges(sample), true)
        XCTAssertEqual(CaptureDirtyRectGate.unknownRepresentationCount, 0)
    }

    /// An attachment nobody can decode must be visible: "the gate could not
    /// tell" and "the gate said no" are otherwise the same silence.
    func testUnknownRepresentationIsCounted() throws {
        let sample = try makeSampleBuffer(dirtyRects: [1, 2, 3] as NSArray as CFArray)
        XCTAssertNil(CaptureDirtyRectGate.frameHasChanges(sample))
        XCTAssertEqual(CaptureDirtyRectGate.unknownRepresentationCount, 1)
        XCTAssertNotNil(CaptureDirtyRectGate.lastUnknownRepresentation)
    }

    /// One undecodable element must not be read as "nothing changed".
    func testMixedArrayIsNotTreatedAsClean() throws {
        let mixed: [Any] = ["origin.x", NSDictionary(dictionary: rectDictionary(CGRect(x: 0, y: 0, width: 4, height: 4)))]
        let sample = try makeSampleBuffer(dirtyRects: mixed as NSArray as CFArray)
        XCTAssertNil(CaptureDirtyRectGate.frameHasChanges(sample))
        XCTAssertEqual(CaptureDirtyRectGate.unknownRepresentationCount, 1)
    }

    func testMissingAttachmentIsNotCountedAsUnknown() throws {
        let sample = try makeSampleBuffer(dirtyRects: nil)
        XCTAssertNil(CaptureDirtyRectGate.frameHasChanges(sample))
        XCTAssertEqual(CaptureDirtyRectGate.unknownRepresentationCount, 0)
    }

    // MARK: - Fixtures

    private func rectDictionary(_ rect: CGRect) -> CFDictionary {
        CGRectCreateDictionaryRepresentation(rect)
    }

    private func dictionaryArray(_ rects: [CGRect]) -> CFArray {
        let dictionaries = rects.map { NSDictionary(dictionary: rectDictionary($0)) }
        return dictionaries as NSArray as CFArray
    }

    private func makeSampleBuffer(dirtyRects: CFArray?) throws -> CMSampleBuffer {
        let description = try CMVideoFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: kCMVideoCodecType_422YpCbCr8),
            width: 64,
            height: 64
        )

        var sampleTiming = CMSampleTimingInfo.invalid
        sampleTiming.duration = CMTime(value: 1, timescale: 60)
        sampleTiming.presentationTimeStamp = CMTime(value: 0, timescale: 60)
        var buffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        XCTAssertEqual(createStatus, noErr)
        let sample = try XCTUnwrap(buffer)

        guard let dirtyRects else { return sample }
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
        )
        let first = try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))
        let attachment = Unmanaged<NSMutableDictionary>.fromOpaque(first).takeUnretainedValue()
        attachment.setObject(dirtyRects, forKey: SCStreamFrameInfo.dirtyRects.rawValue as NSString)
        return sample
    }
}
