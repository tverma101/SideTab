import Foundation
import os

/// Per-stage timing for the host's frame pipeline.
///
/// The repository had no signpost interval, no Instruments template and no
/// per-stage wall-clock breakdown, so the only performance number available was
/// a single end-to-end "frame age" from capture PTS to send. That is enough to
/// see *that* the pipeline is slow but not *where*, which matters because the
/// obvious next question — "would a lower-level language be faster?" — is
/// unanswerable without knowing how much time is spent in Swift glue versus
/// inside VideoToolbox and the kernel.
///
/// These intervals make that question answerable directly in Instruments. They
/// answer the four stages a rewrite would have to target:
///   1. the ScreenCaptureKit callback itself
///   2. the hop onto the encode queue
///   3. `VTCompressionSessionEncodeFrame` (the hardware encoder's submit path)
///   4. the VideoToolbox output callback, where Annex-B framing happens
///
/// Cost when no trace is being recorded is a few nanoseconds per interval:
/// `OSSignposter` returns a nil `SignpostID` and the begin/end calls are
/// no-ops. Intervals are only emitted when the subsystem is enabled, so this
/// does not add work to the frame path in normal operation.
///
/// Record a trace with:
///   xcrun xctrace record --template 'Time Profiler' \
///     --launch -- /Applications/SideTab.app/Contents/MacOS/SideScreen
enum FramePipelineSignpost {
    private static let subsystem = "com.sidescreen.framepipeline"

    // Category names double as the stage labels Instruments displays. These are
    // string literals rather than an enum because `OSSignposter` takes a
    // `StaticString` category, which cannot be a `RawRepresentable` raw type.
    static let captureCallback = OSSignposter(subsystem: subsystem, category: "SCK callback")
    static let encodeQueueHop = OSSignposter(subsystem: subsystem, category: "encode queue hop")
    static let vtEncodeSubmit =
        OSSignposter(subsystem: subsystem, category: "VTCompressionSessionEncodeFrame")
    static let vtOutputCallback =
        OSSignposter(subsystem: subsystem, category: "VT output / Annex-B framing")
    static let socketSend = OSSignposter(subsystem: subsystem, category: "NWConnection send")
}
