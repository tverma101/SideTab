import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
import IOSurface
import IOKit.pwr_mgt
import os

// MARK: - SCStreamDelegate

private class StreamDelegate: NSObject, SCStreamDelegate {
    var onStreamError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        debugLog("SCStream stopped with error — domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
        onStreamError?(error)
    }
}

// MARK: - Continuation plumbing

/// Resumes a checked continuation at most once. Hung work can still finish
/// after its timeout fired, and resuming a continuation a second time traps
/// with SWIFT TASK CONTINUATION MISUSE.
private final class ContinuationOneShot<Value>: @unchecked Sendable {
    private struct State {
        var resumed = false
        var continuation: CheckedContinuation<Value, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ continuation: CheckedContinuation<Value, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Returns true when this call is the one that resumed the continuation.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let pending = state.withLock { state -> CheckedContinuation<Value, Error>? in
            guard !state.resumed else { return nil }
            state.resumed = true
            return state.continuation
        }
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

// MARK: - Encode backpressure

/// Admission control for in-flight encodes. One instance per encode session:
/// a superseded session's still-draining blocks must not be able to push a
/// shared counter below zero, which would disable backpressure for the rest
/// of the session.
struct EncodeBackpressure: @unchecked Sendable {
    private let inFlight = OSAllocatedUnfairLock(initialState: Int32(0))
    private let limit: Int32

    init(limit: Int32 = 2) {
        self.limit = limit
    }

    /// Reserves an encode slot. False means the caller must drop the frame.
    /// A negative count means a drain from another session is still landing,
    /// so the gate fails closed until it catches up.
    func admit() -> Bool {
        inFlight.withLock { counter in
            guard counter >= 0, counter < limit else { return false }
            counter &+= 1
            return true
        }
    }

    /// Returns a slot taken by `admit()`.
    func release() {
        inFlight.withLock { $0 &-= 1 }
    }

    var count: Int32 { inFlight.withLock { $0 } }
}

// MARK: - ScreenCapture

class ScreenCapture {
    private var encoder: VideoEncoder?
    private var virtualDisplayID: CGDirectDisplayID?
    private var refreshRate: Int = 60
    private var frameRateCap: Int?
    /// Transport mode is supplied by AppDelegate once per session. Do not
    /// infer it from an optional FPS cap: a future USB cadence cap must never
    /// enable wireless-only capture/pressure behavior.
    private var connectionMode: ConnectionMode = .usb

    // Thread-safe state for cross-thread access (frame output queue + main queue)
    private let stateLock = OSAllocatedUnfairLock(initialState: FrameMonitorState())

    /// Session state touched by the caller thread, the capture queue, the
    /// encode queue, the network queue and main. These have no thread affinity
    /// to rely on, so every read and write goes through this lock — a plain
    /// property would give the generation fence no happens-before edge.
    private struct SessionState {
        /// Bumped on every stopStreaming and every restart so a superseded
        /// in-flight restart Task aborts instead of resurrecting capture.
        var generation: UInt64 = 0
        /// True between startStreaming and stopStreaming. Guards wake-triggered
        /// restarts from re-enabling capture after a stop.
        var isStreaming = false
        var idlePaused = false
        var idleGeneration: UInt64 = 0
        var stream: SCStream?
        var display: SCDisplay?
        /// Owned by the session rather than by bare properties: setup,
        /// teardown, the fallback path, the frame handler and stopStreaming
        /// all reach these from the capture queue, a restart Task, the
        /// network queue and main. The delegate in particular is also the only
        /// thing that promotes a capture error into recovery, so losing a
        /// reference to it strands the stream silently.
        var streamOutput: StreamOutput?
        var streamDelegate: StreamDelegate?
        var cgDisplayStream: CGDisplayStream?
        /// Set once CGDisplayStream.stop() has been called and stays set until
        /// the kCGDisplayStreamFrameStatusStopped callback has been observed.
        var cgDisplayStreamStopPending = false
        /// True while a restart worker is running an attempt. A request that
        /// arrives while one is in flight still bumps `generation` (so the
        /// in-flight attempt aborts at its next fence) and parks its reason
        /// here; the worker runs it next, which is what keeps the newest
        /// codec and encode dimensions from being lost.
        var restartInFlight = false
        var restartPendingReason: String?
        /// Restart attempts run for this session. Diagnostics and regression
        /// tests; a session that needs many of them is a real failure signal.
        var restartAttempts: UInt64 = 0
    }
    private let sessionLock = OSAllocatedUnfairLock(initialState: SessionState())

    private var streamGeneration: UInt64 { sessionLock.withLock { $0.generation } }
    private var isStreaming: Bool { sessionLock.withLock { $0.isStreaming } }
    var idlePaused: Bool { sessionLock.withLock { $0.idlePaused } }
    private var currentStream: SCStream? { sessionLock.withLock { $0.stream } }
    private var currentStreamOutput: StreamOutput? { sessionLock.withLock { $0.streamOutput } }

    /// Generation + isStreaming fence in a single lock acquisition so callers
    /// never nest sessionLock.
    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        sessionLock.withLock { $0.isStreaming && !$0.idlePaused && $0.generation == gen }
    }

    /// Restart bookkeeping, read-only. Used by the log and by the regression
    /// tests that drive the real restart latch through an injected async gate.
    var restartDebugState: (generation: UInt64, inFlight: Bool, pending: Bool, attempts: UInt64) {
        sessionLock.withLock { ($0.generation, $0.restartInFlight, $0.restartPendingReason != nil, $0.restartAttempts) }
    }

    /// Test seam for the restart worker: awaited after the old stream has been
    /// stopped and before the replacement is published, so a regression test
    /// can hold a rebuild in flight and drive a competing request through the
    /// same latch production uses. Always nil in the app.
    var restartTestGate: (@Sendable () async -> Void)?

    /// Marks the session live without a real capture source. A unit test
    /// cannot create a CGVirtualDisplay, so this is the only way to exercise
    /// the restart latch itself; every restart it triggers then fails fast on
    /// the missing display ID, which is exactly the path the latch must
    /// survive. Internal for tests only.
    func markSessionLiveForTests() {
        sessionLock.withLock { $0.isStreaming = true }
    }

    /// Requests one restart through the production latch. Test-only entry to
    /// the same path wake, codec negotiation and the stall monitor use.
    func requestRestartForTests(reason: String) {
        restartStream(reason: reason)
    }

    /// Drops the stream reference, but only when `gen` still owns it: a
    /// teardown that lost the race to a newer generation must not orphan the
    /// stream that generation built.
    @discardableResult
    private func clearStream(forGeneration gen: UInt64, includingDisplay: Bool = true) -> Bool {
        sessionLock.withLock { state -> Bool in
            guard state.generation == gen else { return false }
            state.stream = nil
            state.streamOutput = nil
            state.streamDelegate = nil
            if includingDisplay { state.display = nil }
            return true
        }
    }

    /// True while no newer session has taken over and nothing is streaming, so
    /// a stop's cleanup still owns the resources it is about to release.
    private func isStoppedGeneration(_ gen: UInt64) -> Bool {
        sessionLock.withLock { !$0.isStreaming && $0.generation == gen }
    }

    /// Hard wall-clock bound for an async API that is known to hang.
    /// `Task.sleep` cannot provide one: a throwing task group always awaits
    /// every child, and `cancelAll()` cannot un-park a hung XPC continuation,
    /// so the timeout branch could never be taken. The work runs unstructured
    /// so a hung call cannot keep the caller suspended.
    static func withBoundedTimeout<Value>(
        seconds: TimeInterval,
        description: String,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = ContinuationOneShot(continuation)
            let budget = String(format: "%g", seconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let timeout = NSError(
                    domain: "ScreenCapture",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "\(description) timed out after \(budget)s"]
                )
                if oneShot.finish(.failure(timeout)) {
                    debugLog("\(description) timed out after \(budget)s")
                }
            }
            Task {
                do {
                    let value = try await operation()
                    if oneShot.finish(.success(value)) { return }
                    debugLog("\(description) completed after its timeout — result discarded")
                } catch {
                    if oneShot.finish(.failure(error)) { return }
                    debugLog("\(description) failed after its timeout: \(error.localizedDescription)")
                }
            }
        }
    }

    /// SCStream.startCapture legitimately takes seconds (2.6-13s measured on a
    /// 2800x1750 virtual display), so its bound is generous; the stop bound is
    /// short because a stop that has not landed in 5s is what leaks the
    /// encoder and its compression session.
    private static let captureStartTimeout: TimeInterval = 20
    private static let captureStopTimeout: TimeInterval = 5

    /// Bounded SCStream.startCapture. Returns false (and logs) on error or
    /// timeout so the caller can fall back instead of awaiting forever.
    private func startCapture(_ target: SCStream?, label: String) async -> Bool {
        guard let target else { return false }
        do {
            try await Self.withBoundedTimeout(
                seconds: Self.captureStartTimeout,
                description: "SCStream.startCapture(\(label))",
                operation: { try await target.startCapture() }
            )
            return true
        } catch {
            debugLog("SCStream startCapture(\(label)) failed: \(error)")
            return false
        }
    }

    /// Bounded SCStream.stopCapture. Never throws: a hung or failing stop must
    /// not strand the caller's cleanup.
    private func stopCapture(_ target: SCStream?, label: String) async {
        guard let target else { return }
        do {
            try await Self.withBoundedTimeout(
                seconds: Self.captureStopTimeout,
                description: "SCStream.stopCapture(\(label))",
                operation: { try await target.stopCapture() }
            )
        } catch {
            debugLog("SCStream stopCapture(\(label)) failed: \(error)")
        }
    }

    // ScreenCaptureKit invokes the output callback on the queue supplied to
    /// addStreamOutput. A dedicated high-priority serial queue keeps capture
    /// ordering deterministic and avoids competing with unrelated global
    /// work while the callback hands off to the encoder.
    private let sampleHandlerQueue = DispatchQueue(
        label: "com.sidescreen.capture.samples",
        qos: .userInteractive
    )

    private struct FrameMonitorState {
        /// Last `.complete` callback — the only status that carries final
        /// pixels. Silence here is normal: ScreenCaptureKit stops delivering
        /// callbacks on an unchanged display, and macOS does not send one even
        /// then, so the monitor must not read it as a failure on its own.
        var lastFrameTime: DispatchTime?
        var hasReceivedFirstFrame = false
        var acceptingFrames = false
        var fallbackActive = false
        /// Last buffer handed to the encoder. Stored here (not in a bare
        /// property) because it is retained across queue boundaries and read
        /// from the network and main queues: a lock-free load racing a store
        /// can release the buffer early and the next dereference faults.
        var lastPixelBuffer: CVPixelBuffer?
        var captureCallbacks: UInt64 = 0
        var idleCallbacks: UInt64 = 0
        var nonCompleteCallbacks: UInt64 = 0
        var dirtyRectSkips: UInt64 = 0
        var pendingEncodeSkips: UInt64 = 0
        var missingImageBufferCallbacks: UInt64 = 0
        var misSizedHdrFrames: UInt64 = 0
        var encodeSubmissions: UInt64 = 0
    }

    private struct CaptureCadenceSnapshot {
        let callbacks: UInt64
        let idleCallbacks: UInt64
        let nonCompleteCallbacks: UInt64
        let dirtyRectSkips: UInt64
        let pendingEncodeSkips: UInt64
        let missingImageBufferCallbacks: UInt64
        let misSizedHdrFrames: UInt64
        let encodeSubmissions: UInt64
    }

    /// A built-but-unpublished capture source. The caller owns it until it
    /// either publishes it under its generation or tears it down; nothing
    /// shared can observe a half-built stream.
    private struct PreparedStream {
        let stream: SCStream
        let output: StreamOutput
        let delegate: StreamDelegate
    }

    private struct KeyframeRequestState {
        var pendingEncoderCreationRequest = false
        var lastKeyframeOrReplayRequestNs: UInt64 = 0
    }
    private let keyframeRequestLock = OSAllocatedUnfairLock(initialState: KeyframeRequestState())
    private static let keyframeRequestThrottleNs: UInt64 = 500_000_000

    private static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments =
            (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]])?.first,
            let rawStatus = attachments[.status]
        else {
            return nil
        }

        if let status = rawStatus as? SCFrameStatus {
            return status
        }
        if let number = rawStatus as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue)
        }
        return nil
    }

    // Main-thread-only state
    private var frameMonitorTimer: DispatchSourceTimer?
    private var restartAttempted = false
    private var wakeObservers: [NSObjectProtocol] = []

    // Display-sleep assertion held while streaming (see createDisplaySleepAssertion)
    private var displaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasDisplaySleepAssertion = false
    private var wakeRestartPending = false

    // Streaming parameters (saved for restart)
    private weak var currentServer: StreamingServer?
    private var currentBitrateMbps: Int = 20
    private var currentQuality: String = "medium"
    private var currentGamingBoost: Bool = false
    private var currentFrameRate: Int = 60
    private var currentBitrateCapMbps: Int?

    /// Preferences are read once per capture session instead of from the
    /// ScreenCaptureKit callback for every frame. These values change only
    /// when a stream is restarted, which keeps the 60/120-FPS path free of
    /// synchronized UserDefaults lookups.
    private struct FramePipelineFlags {
        let wireless: Bool
        let mutatesCapturedPixels: Bool
        let skipsIdenticalFrames: Bool
    }
    private var pipelineFlags = FramePipelineFlags(
        wireless: false,
        mutatesCapturedPixels: false,
        skipsIdenticalFrames: false
    )

    // Encoding pipeline state (captured by frame handler closure)
    private var encodeQueue: DispatchQueue?

    /// Callback when capture method changes (e.g. SCStream → CGDisplayStream fallback)
    var onCaptureMethodChanged: ((String) -> Void)?

    /// Force the encoder to emit an IDR keyframe on the next frame.
    /// If the encoder hasn't been created yet (request arrived before
    /// startStreaming), the request is stored and applied at encoder init.
    func requestKeyframe() {
        // FrameSkipper — every keyframe request also forces the next captured
        // frame through the skip gate (client connect on a static screen must
        // still receive a fresh IDR).
        FrameSkipper.forceNextFrame()
        if let encoder {
            encoder.requestKeyframe()
            return
        }
        keyframeRequestLock.withLock { $0.pendingEncoderCreationRequest = true }
    }

    /// Force a keyframe for the next captured frame, AND immediately re-encode
    /// the last cached frame as a forced keyframe if the display is currently
    /// idle. Without this, a client connecting during a static screen would
    /// wait up to one full GOP duration before its decoder could start.
    func requestKeyframeOrReplayCachedFrame(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldRequest = keyframeRequestLock.withLock { state -> Bool in
            if !force,
               state.lastKeyframeOrReplayRequestNs > 0,
               now - state.lastKeyframeOrReplayRequestNs < Self.keyframeRequestThrottleNs {
                return false
            }
            state.lastKeyframeOrReplayRequestNs = now
            return true
        }
        guard shouldRequest else { return }

        requestKeyframe()

        guard let encoder, let cached = cachedPixelBuffer() else { return }

        let pts = CMTime(
            value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
            timescale: 1_000_000
        )

        encodeQueue?.async {
            guard self.stateLock.withLock({ $0.acceptingFrames }) else { return }
            encoder.encode(pixelBuffer: cached, presentationTimeStamp: pts)
        }
    }

    /// A pixel buffer is not Sendable, so it crosses the lock inside a box —
    /// the box is the part the compiler can see is safe to hand over.
    private struct PixelBufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// The last captured buffer, read under the lock: a lock-free load racing
    /// the capture queue's store can hand the encoder a buffer that was
    /// already released.
    private func cachedPixelBuffer() -> CVPixelBuffer? {
        let box: PixelBufferBox? = stateLock.withLock { state in
            state.lastPixelBuffer.map { PixelBufferBox(buffer: $0) }
        }
        return box?.buffer
    }

    var displayWidth: Int {
        guard let id = virtualDisplayID else { return sessionLock.withLock { $0.display?.width ?? 0 } }
        return ScreenCapture.physicalSize(for: id).width
    }
    var displayHeight: Int {
        guard let id = virtualDisplayID else { return sessionLock.withLock { $0.display?.height ?? 0 } }
        return ScreenCapture.physicalSize(for: id).height
    }

    /// Codec for the current encode session. Switching restarts the stream.
    private(set) var codec: StreamCodec = .hevc

    /// Decoder ceiling reported by the connected client (issue #41). Nil for
    /// legacy clients that report nothing.
    private var clientDecodeLimit: (width: Int, height: Int)?

    /// Encode dimensions for a codec: LOGICAL display pixels for HEVC (so SCK
    /// downscales a HiDPI 2x backing raster — the encoder must never chew 4x
    /// pixels; GATE-422-EXP 2026-08-14), clamped to the client's reported
    /// decoder limit when known, else to the conservative AVC floor when
    /// streaming H.264. SCStream/CGDisplayStream scale the capture into this
    /// size, so no virtual-display change is needed. At 1x, logical == physical.
    func encodeSize(for codec: StreamCodec) -> (width: Int, height: Int) {
        // CAMPAIGN PATCH (2026-08-14): encode the PHYSICAL pixel size, not the
        // logical. The tablet panel is the native physical res (2800x1752);
        // encoding the logical would upscale 2x on the panel (soft). self.width/
        // height return the virtual display's physical size (see above).
        let logical = (width: displayWidth, height: displayHeight)
        // PHASE-3 PATCH (2026-08-14): optional linear encode downscale for the
        // S8+ SGSR1-upscale experiment (0.75 -> 2100x1314 from 2800x1752).
        // SideScreen_encodeScale (UserDefaults, double); 1.0 = native physical.
        // Even-rounded: HEVC 4:2:0 needs even dims.
        let encodeScale = UserDefaults.standard.object(forKey: "SideScreen_encodeScale") as? Double ?? 1.0
        let scale = min(max(encodeScale, 0.25), 1.0)
        var base = logical
        if scale < 1.0 {
            base = (width: (Int((Double(logical.0) * scale).rounded()) & ~1),
                    height: (Int((Double(logical.1) * scale).rounded()) & ~1))
        }
        // A reported limit is authoritative for both codecs: it is what the
        // client's own MediaCodec claims it can decode.
        if let limit = clientDecodeLimit {
            return CodecLimits.clamp(width: base.0, height: base.1,
                                     maxWidth: limit.width, maxHeight: limit.height)
        }
        switch codec {
        case .hevc: return base
        case .h264: return CodecLimits.clampForAvc(width: base.0, height: base.1)
        }
    }

    /// Logical pixel dimensions of the captured display (CGDisplayPixelsWide
    /// returns LOGICAL pixels on HiDPI displays; physicalSize uses the mode's
    /// pixel dims). Falls back to physical when the display ID is unknown.
    var logicalSize: (width: Int, height: Int) {
        let id = virtualDisplayID ?? sessionLock.withLock { $0.display?.displayID } ?? 0
        let w = CGDisplayPixelsWide(id)
        let h = CGDisplayPixelsHigh(id)
        if w > 0 && h > 0 { return (Int(w), Int(h)) }
        return (displayWidth, displayHeight)
    }

    /// Returns physical pixel dimensions for a display ID.
    /// CGDisplayPixelsWide/High return logical pixels on HiDPI displays — use
    /// CGDisplayModeGetPixelWidth/Height to always get the true physical size.
    static func physicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        // Mode lookup failed — falling back to logical pixels (may be stale on HiDPI display)
        debugLog("physicalSize fallback for display \(displayID) — CGDisplayCopyDisplayMode returned nil")
        return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

    init() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("ScreenCapture init — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }

    /// Setup screen capture for a specific virtual display
    func setupForVirtualDisplay(
        _ displayID: CGDirectDisplayID,
        refreshRate: Int = 60,
        frameRateCap: Int? = nil,
        connectionMode: ConnectionMode = .usb
    ) async throws {
        self.virtualDisplayID = displayID
        self.refreshRate = refreshRate
        self.frameRateCap = frameRateCap
        self.connectionMode = connectionMode
        let display = try await setupDisplay()
        // Initial setup runs before any generation exists, so this publication
        // is unconditional. Every later rebuild goes through restartStream(),
        // which owns the generation fence.
        let prepared = try await prepareStream(display: display)
        sessionLock.withLock { state in
            state.display = display
            state.stream = prepared.stream
            state.streamOutput = prepared.output
            state.streamDelegate = prepared.delegate
        }
        await MainActor.run { registerWakeObservers() }
    }

    // MARK: - Display wake handling

    /// Display sleep tears down SCStream (SCStreamErrorDomain -3815, "no
    /// displays or windows to capture"), which silently drops capture onto
    /// the CGDisplayStream fallback for the rest of the session. Restart
    /// the capture whenever the screens wake so it returns to SCStream.
    private func registerWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            wakeObservers.append(token)
        }
        debugLog("Wake observers registered")
    }

    private func unregisterWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    deinit {
        // Defensive: stopStreaming() already unregisters, but make sure a
        // dropped instance never leaves observer tokens behind.
        unregisterWakeObservers()
    }

    private func handleWake() {
        // Only act while a capture is actually running.
        guard hasLiveCaptureSource else { return }
        // A full system wake fires both screensDidWake and didWake —
        // coalesce them into a single restart.
        guard !wakeRestartPending else { return }
        wakeRestartPending = true
        debugLog("Screens woke — scheduling capture restart")
        // Give WindowServer a moment to settle before touching the stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.wakeRestartPending = false
            guard self.hasLiveCaptureSource else { return }
            // Display sleep usually kills SCStream with error -3815 ("no
            // displays or windows to capture"), which pushes capture onto the
            // CGDisplayStream fallback. After wake, always try to get back
            // onto SCStream — restartStream() tears the fallback down and
            // re-enters it by itself if SCStream still cannot start.
            if self.stateLock.withLock({ $0.fallbackActive }) {
                debugLog("Wake restart: leaving CGDisplayStream fallback, retrying SCStream")
            }
            self.restartStream(reason: "display wake")
            // A wake-triggered restart must not consume the one-shot budget
            // the frame monitor uses for stall recovery.
            self.setRestartAttempted(false)
        }
    }

    private var hasLiveCaptureSource: Bool {
        sessionLock.withLock { $0.stream != nil || $0.cgDisplayStream != nil }
    }

    // MARK: - SCShareableContent with timeout

    /// Bounded SCShareableContent. `excludingDesktopWindows` hangs on some
    /// builds (Apple bug FB12114396), so the caller's await must be able to
    /// unblock on a timer instead of waiting on the hung XPC call.
    private func getShareableContentWithTimeout(seconds: Int = 10) async throws -> SCShareableContent {
        try await Self.withBoundedTimeout(
            seconds: TimeInterval(seconds),
            description: "SCShareableContent.excludingDesktopWindows (possible Apple bug FB12114396)",
            operation: {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        )
    }

    // MARK: - Display setup

    /// Resolves the capture target. Returns the display instead of publishing
    /// it: a rebuild can spend tens of seconds in here, and a caller whose
    /// generation was superseded in the meantime must be able to drop the
    /// result rather than overwrite the state a newer stream owns.
    private func setupDisplay() async throws -> SCDisplay {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        for attempt in 1...5 {
            let content: SCShareableContent
            do {
                content = try await getShareableContentWithTimeout(seconds: 10)
            } catch {
                debugLog("SCShareableContent attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }

            debugLog("SCShareableContent returned \(content.displays.count) displays: \(content.displays.map { $0.displayID })")

            if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return virtualDisplay
            }

            if attempt < 5 {
                debugLog("Virtual display \(virtualDisplayID) not found in attempt \(attempt), retrying...")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw NSError(domain: "ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found after 5 attempts"])
    }

    // MARK: - Stream setup

    /// Builds a fully wired stream and hands ownership to the caller. Nothing
    /// is published here, so a caller that loses its generation race can
    /// explicitly tear the result down instead of leaving a live
    /// ScreenCaptureKit stream and its IOSurfaces unreachable.
    private func prepareStream(display: SCDisplay) async throws -> PreparedStream {
        guard virtualDisplayID != nil else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }
        // Physical pixels for full Retina sharpness, clamped when H.264 (SCStream scales)
        let (width, height) = encodeSize(for: codec)
        // EXP-FORK: HDR mode — the converter's buffer pool is sized by the
        // first session that calls ensureSetup, and codec negotiation can
        // change the encode size on every restart, so re-arm it here with the
        // size this stream is actually configured for.
        if HDRConverter.enabled {
            HDRConverter.ensureSetup(width: width, height: height)
        }
        // EXP-FORK: SideScreen_exp_fps caps the capture cadence (e.g. 90) —
        // a stable 90 beats a jittery 120 when the pipeline can't hold 120.
        let expFps = UserDefaults.standard.integer(forKey: "SideScreen_exp_fps")
        let requestedFps = expFps > 0 ? expFps : refreshRate
        let fps = min(max(1, requestedFps), frameRateCap ?? Int.max)

        let output = StreamOutput()

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self, weak delegate] _ in
            guard let self, let delegate,
                  self.sessionLock.withLock({ $0.isStreaming && !$0.idlePaused && $0.streamDelegate === delegate }) else { return }
            debugLog("StreamDelegate error callback — attempting fallback")
            let alreadyActive = self.stateLock.withLock { $0.fallbackActive }
            if !alreadyActive {
                self.attemptFallbackCapture()
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // The normal 8-bit SDR path is video-range so the sender agrees with
        // Android's hardware decoder conversion. `8bit` remains an explicit
        // full-range A/B control; `10bit` remains the Main10 video-range path.
        let capturePixelFormat = VideoColorProfile.configuredCapturePixelFormat()
        config.pixelFormat = capturePixelFormat
        debugLog("Stream color profile: \(VideoColorProfile.rangeName(capturePixelFormat))")

        // EXP-FORK knob (absent = no explicit color-space override):
        //   SideScreen_exp_colorSpace "displayP3" | "bt2020" | "srgb"
        switch UserDefaults.standard.string(forKey: "SideScreen_exp_colorSpace") {
        case "displayP3":
            config.colorSpaceName = "kCGColorSpaceDisplayP3" as CFString
        case "bt2020":
            config.colorSpaceName = "kCGColorSpaceITUR_2020" as CFString
        case "srgb":
            config.colorSpaceName = "kCGColorSpaceSRGB" as CFString
        default:
            break // leave SCKit's default (current production behavior)
        }
        config.showsCursor = true
        // Keep four capture surfaces available. ScreenCaptureKit can otherwise
        // starve the callback when VideoToolbox is still holding a pixel buffer
        // during a high-resolution wireless frame, reducing source cadence
        // before transport pressure has any chance to engage.
        config.queueDepth = 4
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        do {
            try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        } catch {
            // addStreamOutput is the last thing that can throw; the stream was
            // never published, so drop it here rather than letting it go out
            // of scope with an output installed.
            debugLog("SCStream addStreamOutput failed: \(error)")
            throw error
        }

        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps (with delegate)")
        return PreparedStream(stream: scStream, output: output, delegate: delegate)
    }

    // MARK: - Shared frame handler (used by both startStreaming and restartStream)

    private func configureFrameHandler(label: String, output: StreamOutput) {
        let queue = DispatchQueue(label: "encodeQueue.\(label)", qos: .userInteractive)
        // A fresh counter per session: the previous encode queue can still be
        // draining blocks that decrement the old counter, so sharing one
        // counter let it go negative and disabled backpressure for the rest of
        // the session.
        let backpressure = EncodeBackpressure()
        encodeQueue = queue
        stateLock.withLock { $0.lastPixelBuffer = nil }
        let sessionFlags = pipelineFlags
        let sessionSize = encodeSize(for: codec)

        output.onFrameReceived = { [weak self, weak output] sampleBuffer in
            guard let self, let output, self.currentStreamOutput === output else { return }
            // Spans the whole ScreenCaptureKit callback, which is the only stage
            // this file owns. See FramePipelineSignpost for why. The category is
            // fixed; the complete/idle distinction this callback already
            // computes is reported through the existing cadence counters.
            let pipelineSignpost = FramePipelineSignpost.captureCallback.beginInterval("frame")
            defer { FramePipelineSignpost.captureCallback.endInterval("frame", pipelineSignpost) }
            guard self.stateLock.withLock({ $0.acceptingFrames }) else { return }
            let frameStatus = Self.frameStatus(sampleBuffer)

            // The status read is unconditional now: the `.complete` gate below
            // has to run on every transport. Only the cadence counters stay
            // wireless-only, because its bounded freshness policy needs them.
            let cadence: CaptureCadenceSnapshot?
            if sessionFlags.wireless {
                cadence = self.stateLock.withLock { state -> CaptureCadenceSnapshot? in
                    state.captureCallbacks &+= 1
                    if frameStatus == .idle {
                        state.idleCallbacks &+= 1
                    }
                    if frameStatus != .complete {
                        state.nonCompleteCallbacks &+= 1
                    }
                    return state.captureCallbacks.isMultiple(of: 120)
                        ? CaptureCadenceSnapshot(
                            callbacks: state.captureCallbacks,
                            idleCallbacks: state.idleCallbacks,
                            nonCompleteCallbacks: state.nonCompleteCallbacks,
                            dirtyRectSkips: state.dirtyRectSkips,
                            pendingEncodeSkips: state.pendingEncodeSkips,
                            missingImageBufferCallbacks: state.missingImageBufferCallbacks,
                            misSizedHdrFrames: state.misSizedHdrFrames,
                            encodeSubmissions: state.encodeSubmissions
                        )
                        : nil
                }
            } else {
                cadence = nil
            }

            // `.started` is a warmup frame with no final pixels, and `.idle` /
            // `.blank` mean no new IOSurface arrived. None of them may count
            // as liveness (that would make a heartbeat-only stream look
            // healthy) or reach the encoder.
            guard frameStatus == .complete else { return }

            let isFirst = self.stateLock.withLock { state -> Bool in
                state.lastFrameTime = DispatchTime.now()
                if !state.hasReceivedFirstFrame {
                    state.hasReceivedFirstFrame = true
                    return true
                }
                return false
            }

            if isFirst {
                debugLog("First frame received from SCStream (\(label))")
                let bufferSize = CMSampleBufferGetImageBuffer(sampleBuffer).map {
                    "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))"
                } ?? "none"
                let frameInfo =
                    (CMSampleBufferGetSampleAttachmentsArray(
                        sampleBuffer,
                        createIfNecessary: false
                    ) as? [[SCStreamFrameInfo: Any]])?.first
                let contentRect = frameInfo?[.contentRect] ?? "missing"
                let contentScale = frameInfo?[.contentScale] ?? "missing"
                let scaleFactor = frameInfo?[.scaleFactor] ?? "missing"
                debugLog(
                    "SCStream frame geometry: buffer=\(bufferSize), " +
                    "contentRect=\(contentRect), contentScale=\(contentScale), " +
                    "scaleFactor=\(scaleFactor)"
                )
                self.onCaptureMethodChanged?("SCStream")
            }
            if let cadence {
                debugLog(
                    "Capture cadence: callbacks=\(cadence.callbacks), " +
                    "idle=\(cadence.idleCallbacks), " +
                    "nonComplete=\(cadence.nonCompleteCallbacks), " +
                    "dirtySkips=\(cadence.dirtyRectSkips), " +
                    "pendingSkips=\(cadence.pendingEncodeSkips), " +
                    "missingImage=\(cadence.missingImageBufferCallbacks), " +
                    "misSizedHdr=\(cadence.misSizedHdrFrames), " +
                    "encodeSubmissions=\(cadence.encodeSubmissions)"
                )
            }

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                if sessionFlags.wireless {
                    self.stateLock.withLock { $0.missingImageBufferCallbacks &+= 1 }
                }
                return
            }

            // ScreenCaptureKit already tells us whether anything in the frame
            // changed. An explicitly empty dirty-rect array lets either
            // transport avoid VideoToolbox, network work, Android decode, and
            // presentation. Missing/unrecognized metadata encodes normally.
            // Synthetic pattern/dither experiments mutate pixels after capture,
            // so they deliberately bypass this gate.
            let frameHasChanges = CaptureDirtyRectGate.frameHasChanges(sampleBuffer)
            if CaptureDirtyRectGate.shouldSkip(
                frameHasChanges: frameHasChanges,
                mutatesCapturedPixels: sessionFlags.mutatesCapturedPixels
            ) {
                self.stateLock.withLock { $0.dirtyRectSkips &+= 1 }
                return
            }

            // USB above 60 Hz: capture keeps sampling at the configured rate,
            // but the encode cadence follows USBAdaptiveLoadController's
            // 120 -> 90 -> 60 motion ladder under sustained pressure. Clean
            // frames never reach this point, so the pacer only paces motion;
            // the first changed frame after an idle spell always goes out.
            if !sessionFlags.wireless,
               USBAdaptiveFramePacer.shared.shouldSkip(
                   frameHasChanges: frameHasChanges,
                   mutatesCapturedPixels: sessionFlags.mutatesCapturedPixels
               ) {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Backpressure: admit at most 2 in-flight encodes.
            guard backpressure.admit() else {
                if sessionFlags.wireless {
                    self.stateLock.withLock { $0.pendingEncodeSkips &+= 1 }
                }
                return
            }
            var enqueued = false
            defer {
                if !enqueued { backpressure.release() }
            }

            // EXP-FORK: inject synthetic test patterns (SideScreen_exp_pattern)
            // so experiments measure known pixels, not the user's desktop.
            if PatternInjector.isActive() {
                PatternInjector.fill(imageBuffer)
            }
            // EXP-FORK: dither (SideScreen_exp_dither) — slope-adaptive
            // blue noise on the 8-bit Y plane, AFTER pattern injection
            // so injected patterns are measured dithered too.
            if DitherPass.enabled {
                DitherPass.apply(imageBuffer)
            }
            // FrameSkipper (efficiency Lever 1, Entry U) — skip
            // pixel-identical frames (SideScreen_exp_skipFrames=1).
            // Liveness was already updated above, so the early return cannot
            // false-trigger the stall monitor.
            if sessionFlags.skipsIdenticalFrames {
                let decision = FrameSkipper.decide(imageBuffer)
                if decision.skip {
                    return  // identical content — skip encode+send
                }
                FrameSkipper.noteSent(hash: decision.hash)
            }
            // EXP-FORK: HDR mode (SideScreen_exp_hdr) — convert the 8-bit
            // capture to 10-bit PQ/BT.2020 before encoding so the tablet's
            // HDR path engages (AMOLED gradient fix). The converted buffer
            // is pooled (4 deep) and safe to hand to the async encode.
            var toEncode = imageBuffer
            if HDRConverter.enabled {
                if let hdr = HDRConverter.convert(imageBuffer) {
                    // A converter pool sized for another session would resample
                    // into the wrong geometry; drop the frame rather than ship
                    // mis-sized pixels to a fixed-size encoder.
                    if CVPixelBufferGetWidth(hdr) != sessionSize.width
                        || CVPixelBufferGetHeight(hdr) != sessionSize.height {
                        self.stateLock.withLock { $0.misSizedHdrFrames &+= 1 }
                        debugLog(
                            "HDRConverter: \(CVPixelBufferGetWidth(hdr))x\(CVPixelBufferGetHeight(hdr)) " +
                            "does not match encode size \(sessionSize.width)x\(sessionSize.height) — frame dropped"
                        )
                        return
                    }
                    toEncode = hdr
                } else {
                    debugLog("HDRConverter: convert failed — falling back to 8-bit")
                }
            }
            let frameToEncode = PixelBufferBox(buffer: toEncode)
            self.stateLock.withLock { state in
                state.lastPixelBuffer = frameToEncode.buffer
                if sessionFlags.wireless {
                    state.encodeSubmissions &+= 1
                }
            }
            queue.async {
                let hopSignpost = FramePipelineSignpost.encodeQueueHop.beginInterval("hop")
                if self.stateLock.withLock({ $0.acceptingFrames }) {
                    self.encoder?.encode(pixelBuffer: frameToEncode.buffer, presentationTimeStamp: pts)
                }
                backpressure.release()
                FramePipelineSignpost.encodeQueueHop.endInterval("hop", hopSignpost)
            }
            enqueued = true
        }
    }

    // MARK: - Start streaming

    func startStreaming(
        to server: StreamingServer?,
        bitrateMbps: Int = 20,
        quality: String = "medium",
        gamingBoost: Bool = false,
        frameRate: Int = 60,
        bitrateCapMbps: Int? = nil,
        frameRateCap: Int? = nil,
        connectionMode: ConnectionMode = .usb
    ) {
        // Read the built stream's output before publishing a live session: a
        // start without one would otherwise leave isStreaming = true with no
        // way to ever deliver a frame.
        guard let initialOutput = currentStreamOutput, let initialStream = currentStream else {
            debugLog("startStreaming skipped — capture was never set up")
            return
        }
        let sessionGeneration: UInt64 = sessionLock.withLock { state -> UInt64 in
            state.generation &+= 1
            state.isStreaming = true
            return state.generation
        }
        // Save parameters for potential restart
        currentServer = server
        self.frameRateCap = frameRateCap
        self.connectionMode = connectionMode
        pipelineFlags = FramePipelineFlags(
            wireless: connectionMode == .wireless,
            mutatesCapturedPixels: PatternInjector.isActive() || DitherPass.enabled,
            skipsIdenticalFrames: FrameSkipper.enabled
        )
        currentBitrateCapMbps = bitrateCapMbps
        // EXP-FORK: SideScreen_exp_fps cap applies to the encoder too (rate
        // control must expect the same cadence the capture actually delivers).
        let expFps = UserDefaults.standard.integer(forKey: "SideScreen_exp_fps")
        let requestedFrameRate = expFps > 0 ? expFps : frameRate
        let effFrameRate = min(max(1, requestedFrameRate), self.frameRateCap ?? Int.max)
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        currentFrameRate = effFrameRate

        // Keep the display awake while a tablet is attached. The idle monitor
        // releases this assertion after its no-client grace period.
        createDisplaySleepAssertion()

        let (width, height) = encodeSize(for: codec)

        // EXP-FORK: HDR mode — prepare the 10-bit converter pool + LUTs for the
        // capture size up front (first frame would race the encode otherwise).
        if HDRConverter.enabled {
            HDRConverter.ensureSetup(width: width, height: height)
        }

        encoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost, frameRate: effFrameRate, maxBitrateMbps: currentBitrateCapMbps, wireless: pipelineFlags.wireless)
        encoder?.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }

        // Apply any keyframe request that arrived before the encoder existed
        let shouldForceInitialKeyframe = keyframeRequestLock.withLock { state -> Bool in
            guard state.pendingEncoderCreationRequest else { return false }
            state.pendingEncoderCreationRequest = false
            return true
        }
        if shouldForceInitialKeyframe {
            encoder?.requestKeyframe()
        }

        // Reset frame monitor state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
            state.acceptingFrames = true
        }

        configureFrameHandler(label: "initial", output: initialOutput)

        let streamToStart = initialStream
        Task {
            // startCapture can take seconds. A Stop (or a restart) in that
            // window must not let this Task arm the monitor or engage the
            // CGDisplayStream fallback on a session that is no longer running.
            let started = await self.startCapture(streamToStart, label: "initial")
            guard isCurrentGeneration(sessionGeneration) else {
                debugLog("startStreaming(gen \(sessionGeneration)) superseded — monitor and fallback skipped")
                await self.stopCapture(streamToStart, label: "initial-abort")
                return
            }
            if started {
                debugLog("SCStream capture started — starting frame flow monitor (3s interval, 5s timeout)")
                startFrameMonitor()
            } else {
                debugLog("Attempting CGDisplayStream fallback due to start failure")
                attemptFallbackCapture()
            }
        }
    }

    // MARK: - Continuous frame-flow monitor

    private func startFrameMonitor() {
        // The monitor is main-queue state but is armed from Tasks that do not
        // run on main. Hopping keeps the create/assign/cancel sequence from
        // interleaving, which could leave a resumed-but-unreferenced timer
        // firing for the lifetime of the process.
        DispatchQueue.main.async {
            self.armFrameMonitor()
        }
    }

    private func armFrameMonitor() {
        guard isStreaming, !idlePaused else { return }
        // Idempotent swap: an arm that arrives while a timer is live cancels
        // the old one first, so exactly one timer can ever be live.
        stopFrameMonitor()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.frameMonitorTick()
        }
        timer.resume()
        frameMonitorTimer = timer
    }

    private func stopFrameMonitor() {
        if Thread.isMainThread {
            frameMonitorTimer?.cancel()
            frameMonitorTimer = nil
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.frameMonitorTimer?.cancel()
            self?.frameMonitorTimer = nil
        }
    }

    private func frameMonitorTick() {
        let isFallback = stateLock.withLock { $0.fallbackActive }
        guard !isFallback else {
            stopFrameMonitor()
            return
        }
        // The monitor is armed from a Task that has no thread affinity and
        // re-armed after every restart, so it must be fenced: an idle pause
        // stops the capture on purpose, and a torn-down session must not have
        // its "no frames yet" grace spent on recovery.
        guard isStreaming, !idlePaused else { return }

        // Only the initial grace is a failure signal: SCK never delivered a
        // complete frame after `startCapture` succeeded. Silence *after* a
        // frame is normal — ScreenCaptureKit stops delivering on an unchanged
        // display and macOS does not even send a callback then — so a quiet
        // desktop must never restart a 2.6-13s stream setup.
        let (hasHadFrames, hasCachedFrame, lastFrame) = stateLock.withLock {
            ($0.hasReceivedFirstFrame, $0.lastPixelBuffer != nil, $0.lastFrameTime)
        }
        let stalled: Bool
        if let lastFrame {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastFrame.uptimeNanoseconds) / 1_000_000_000
            stalled = elapsed > 5.0
        } else {
            stalled = true
        }
        guard stalled else { return }

        if hasHadFrames, hasCachedFrame {
            // Quiet after a healthy stream: leave the monitor armed (it costs one
            // timer tick per 3s and stays correct if the display wakes) and do
            // not spend the restart budget. Real capture failures still arrive
            // through StreamDelegate.
            return
        }
        debugLog("Frame flow stalled — no frames received after 5s, triggering recovery")
        if !restartAttempted {
            debugLog("Attempting SCStream restart...")
            restartStream(reason: "no frames after start")
        } else {
            debugLog("Restart already attempted — falling back to CGDisplayStream")
            stopFrameMonitor()
            attemptFallbackCapture()
        }
    }

    private func setRestartAttempted(_ value: Bool) {
        if Thread.isMainThread {
            restartAttempted = value
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.restartAttempted = value
        }
    }

    // MARK: - Idle sleep (no client connected)

    /// Pause capture+encode while no client is connected — CPU drops to ~0.
    /// Generation-guarded like restartStream so a rapid pause/resume race
    /// cannot strand capture in the wrong state (worst case: a brief extra
    /// stop/start; end state is always "capturing when a client is present").
    /// The frame monitor is stopped so its stall detector does not treat the
    /// pause as a dead stream and trigger the CGDisplayStream fallback.
    func pauseForIdle() {
        guard !stateLock.withLock({ $0.fallbackActive }) else {
            debugLog("IDLE: pause skipped — CGDisplayStream fallback is active")
            return
        }
        let gen: UInt64? = sessionLock.withLock { state -> UInt64? in
            guard !state.idlePaused, state.isStreaming, state.stream != nil else { return nil }
            state.idlePaused = true
            state.generation &+= 1
            state.restartPendingReason = nil
            state.idleGeneration &+= 1
            return state.idleGeneration
        }
        guard let gen else { return }
        stopFrameMonitor()
        // A pause invalidates every liveness signal: the paused stream is
        // stopped and the resumed one is a different object, so the stall
        // monitor must not treat the old session's "already received frames"
        // as proof that the new stream is alive.
        stateLock.withLock { $0.hasReceivedFirstFrame = false }
        debugLog("IDLE: pausing capture (no client)")
        // There is no active display consumer now. Releasing this assertion is
        // what lets macOS lower the panel/system power state during idle.
        releaseDisplaySleepAssertion()
        let streamToStop = currentStream
        Task {
            await self.stopCapture(streamToStop, label: "idle-pause(gen \(gen))")
            let stillPaused = sessionLock.withLock { state in
                state.isStreaming && state.idlePaused && state.idleGeneration == gen
            }
            if !stillPaused {
                // Superseded by a resume, which rebuilds the stream from
                // scratch — calling startCapture on a stopped SCStream fails
                // with SCStreamError.Code.attemptToStartStreamState (-3807).
                debugLog("IDLE: pause superseded — leaving the resume path in charge")
                return
            }
            debugLog("IDLE: capture paused — CPU sleep")
        }
    }

    /// Resume capture on client connect. The caller forces a keyframe /
    /// replays the cached frame right after, so the client sees pixels
    /// immediately even while the SCStream restarts underneath.
    func resumeFromIdle() {
        let resumed = sessionLock.withLock { state -> Bool in
            guard state.idlePaused else { return false }
            state.idlePaused = false
            state.idleGeneration &+= 1
            return true
        }
        guard resumed else { return }
        createDisplaySleepAssertion()
        guard isStreaming else {
            debugLog("IDLE: resume skipped — not streaming")
            return
        }
        // SCStream cannot be restarted once stopped (-3807), so a resume has
        // to build a fresh stream rather than call startCapture again.
        debugLog("IDLE: resuming capture (client connected) — rebuilding SCStream")
        restartStream(reason: "resume from idle")
        // An idle resume is not a stall, so it must not consume the one-shot
        // restart budget the frame monitor spends on recovery.
        setRestartAttempted(false)
    }

    // MARK: - Stream restart

    /// Requests one rebuild of the capture source.
    ///
    /// Restart triggers genuinely overlap: display wake and the frame monitor
    /// arrive on main, `onCodecNegotiated` arrives on StreamingServer's network
    /// queue, and the idle resume arrives on main. Running them concurrently
    /// let a slower, already-superseded attempt publish its half-built
    /// `SCStream` over a newer generation's live one — leaking a started
    /// ScreenCaptureKit stream every time it raced, and leaving `currentStream`
    /// pointing at an object nothing ever stops.
    ///
    /// So requests are latched rather than run concurrently: each one bumps
    /// `generation` (which makes the in-flight attempt abort at its next
    /// fence) and records its reason; a single worker builds and publishes,
    /// then loops for the newest request if one arrived while it worked. The
    /// newest codec and encode dimensions therefore win — a coalesced request
    /// is never dropped, just applied later.
    private func restartStream(reason: String) {
        enum Latch {
            case start
            case fold
            case notStreaming
        }
        let latch: Latch = sessionLock.withLock { state -> Latch in
            guard state.isStreaming, !state.idlePaused else { return .notStreaming }
            state.generation &+= 1
            state.restartPendingReason = reason
            guard !state.restartInFlight else { return .fold }
            state.restartInFlight = true
            return .start
        }
        switch latch {
        case .notStreaming:
            debugLog("restartStream(\(reason)) skipped — not streaming")
            return
        case .fold:
            debugLog("restartStream(\(reason)) folded into the in-flight rebuild")
            return
        case .start:
            break
        }
        setRestartAttempted(true)
        Task { await self.runRestartWorker() }
    }

    private func runRestartWorker() async {
        while true {
            let request: (reason: String, gen: UInt64)? = sessionLock.withLock { state in
                guard state.isStreaming, !state.idlePaused else {
                    state.restartPendingReason = nil
                    return nil
                }
                guard let reason = state.restartPendingReason else { return nil }
                state.restartPendingReason = nil
                state.restartAttempts &+= 1
                return (reason, state.generation)
            }
            guard let request else {
                // Release the latch only while no newer request is parked, so a
                // request that lands between this check and the clear cannot be
                // left with nothing running it.
                let drained: Bool = sessionLock.withLock { state in
                    guard state.restartPendingReason == nil else { return false }
                    state.restartInFlight = false
                    return true
                }
                if drained { return }
                continue
            }
            await performRestart(reason: request.reason, gen: request.gen)
        }
    }

    /// One rebuild attempt. Owns every object it creates until either
    /// publication succeeds under `gen` or the object is explicitly stopped.
    private func performRestart(reason: String, gen: UInt64) async {
        guard isCurrentGeneration(gen) else { return }
        debugLog("restartStream(gen \(gen)) — \(reason)")

        // A live CGDisplayStream would keep encoding into the encoder being
        // rebuilt at the old dimensions while the new SCStream comes up.
        if stateLock.withLock({ $0.fallbackActive }) {
            debugLog("restartStream: stopping CGDisplayStream fallback before rebuilding SCStream")
            stopFallbackDisplayStream(reason: "restartStream")
            stateLock.withLock { $0.fallbackActive = false }
        }

        // Every liveness signal belongs to the stream being replaced.
        stateLock.withLock { state in
            state.hasReceivedFirstFrame = false
            state.lastFrameTime = nil
        }
        // Captured before the await: reading the live reference afterwards could
        // stop a stream a newer generation has already built.
        let streamToStop = currentStream
        await stopCapture(streamToStop, label: "restart(gen \(gen))")

        // A stopStreaming() or a newer restart superseded this one — do NOT
        // bring capture back up (would resurrect a stopped stream).
        guard isCurrentGeneration(gen) else {
            debugLog("restartStream(gen \(gen)) superseded after stopCapture — aborting")
            return
        }

        clearStream(forGeneration: gen)

        if let gate = restartTestGate {
            await gate()
        }

        do {
            let display = try await setupDisplay()
            let prepared = try await prepareStream(display: display)
            // Single fenced publication. Everything the stream needs lands in
            // one lock acquisition, so no observer can ever see a stream
            // without its output/delegate or vice versa, and a superseded
            // attempt cannot overwrite the state a newer generation owns.
            let published = sessionLock.withLock { state -> Bool in
                guard state.isStreaming, state.generation == gen else { return false }
                state.display = display
                state.stream = prepared.stream
                state.streamOutput = prepared.output
                state.streamDelegate = prepared.delegate
                return true
            }
            guard published else {
                debugLog("restartStream(gen \(gen)) superseded before publication — stopping the unstarted stream")
                await stopCapture(prepared.stream, label: "restart-abort(gen \(gen))")
                return
            }

            // Re-attach the encoding pipeline to the stream that was just
            // published (the previous output belonged to the replaced stream).
            configureFrameHandler(label: "restart", output: prepared.output)
            // Aborts stop the object this attempt owns, not a lookup by
            // generation: once a newer generation exists the lookup returns
            // nil by design, which used to leave this freshly built stream
            // running forever. A newer attempt may already have stopped it,
            // in which case stopCapture logs SCK's -3808 and moves on.
            guard isCurrentGeneration(gen) else {
                debugLog("restartStream(gen \(gen)) superseded before start — aborting")
                await stopCapture(prepared.stream, label: "restart-abort(gen \(gen))")
                return
            }

            let started = await startCapture(prepared.stream, label: "restart(gen \(gen))")
            guard isCurrentGeneration(gen) else {
                debugLog("restartStream(gen \(gen)) superseded after startCapture — aborting")
                await stopCapture(prepared.stream, label: "restart-abort(gen \(gen))")
                return
            }
            guard started else {
                debugLog("restartStream(gen \(gen)) could not start — falling back to CGDisplayStream")
                attemptFallbackCapture()
                return
            }

            debugLog("SCStream restarted — starting frame flow monitor")
            startFrameMonitor()
        } catch {
            debugLog("SCStream restart failed: \(error) — falling back to CGDisplayStream")
            if isCurrentGeneration(gen) {
                attemptFallbackCapture()
            } else {
                debugLog("restartStream(gen \(gen)) superseded before fallback — aborted")
            }
        }
    }

    // MARK: - Display-sleep assertion

    /// Keep the display awake while streaming. The captured surface is a
    /// virtual display; when the physical display idle-sleeps (pmset
    /// displaysleep), the virtual display stops producing frames and the
    /// cursor overlay is lost on wake. Holding
    /// kIOPMAssertionTypePreventUserIdleDisplaySleep avoids the whole
    /// sleep/wake transition; the wake observers above cover what it cannot
    /// (manual/forced sleep, lid close, display reconnects). Released in
    /// stopStreaming.
    private func createDisplaySleepAssertion() {
        guard !hasDisplaySleepAssertion else { return }
        let reason = "SideTab is streaming to an external tablet display" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID)
        if result == kIOReturnSuccess {
            hasDisplaySleepAssertion = true
            debugLog("Display-sleep assertion held — display stays awake while streaming")
        } else {
            debugLog("Failed to create display-sleep assertion: IOReturn \(result)")
        }
    }

    private func releaseDisplaySleepAssertion() {
        guard hasDisplaySleepAssertion else { return }
        let result = IOPMAssertionRelease(displaySleepAssertionID)
        if result != kIOReturnSuccess {
            debugLog("IOPMAssertionRelease failed: IOReturn \(result)")
        }
        hasDisplaySleepAssertion = false
        displaySleepAssertionID = IOPMAssertionID(0)
        debugLog("Display-sleep assertion released")
    }

    // MARK: - CGDisplayStream fallback

    private func attemptFallbackCapture() {
        // A start failure or a stream error can land after the user stopped
        // streaming. Engaging the fallback then would keep a CGDisplayStream
        // encoding into a released encoder for the rest of the process.
        guard isStreaming else {
            debugLog("Fallback skipped — not streaming")
            return
        }
        guard let displayID = virtualDisplayID else {
            debugLog("Fallback skipped — no displayID")
            return
        }

        // Thread-safe check-and-set for fallbackActive
        let alreadyActive = stateLock.withLock { state -> Bool in
            if state.fallbackActive { return true }
            state.fallbackActive = true
            return false
        }
        guard !alreadyActive else {
            debugLog("Fallback skipped — already active")
            return
        }

        // Stop SCStream (nil out output first to prevent new frames)
        let gen = streamGeneration
        currentStreamOutput?.onFrameReceived = nil
        let streamToStop = currentStream
        Task {
            await stopCapture(streamToStop, label: "fallback-teardown(gen \(gen))")
            // A display wake can rebuild a fresh stream while this teardown
            // waits inside stopCapture; dropping that new stream would end
            // capture silently for the rest of the session.
            if clearStream(forGeneration: gen, includingDisplay: false) {
                debugLog("CGDisplayStream fallback: SCStream torn down (gen \(gen))")
            } else {
                debugLog("CGDisplayStream fallback: SCStream teardown superseded (gen \(gen)) — new stream left running")
            }
        }

        // CGDisplayStream scales natively via outputWidth/Height, so the
        // AVC clamp applies here exactly as in the SCStream path.
        let (width, height) = encodeSize(for: codec)

        debugLog("CGDisplayStream fallback — display \(displayID) (\(width)x\(height))")

        let fallbackPixelFormat = VideoColorProfile.fallbackCapturePixelFormat()
        let pixelFormat = Int32(fallbackPixelFormat)
        debugLog("CGDisplayStream color profile: \(VideoColorProfile.rangeName(fallbackPixelFormat))")
        let queue = DispatchQueue(label: "com.sidescreen.cgdisplaystream", qos: .userInteractive)

        // Without kCGDisplayStreamShowCursor the fallback stream never
        // composites the cursor at all (the key defaults to false), so any
        // session that degrades to CGDisplayStream loses the pointer on the
        // tablet even when WindowServer is healthy.
        let streamProps = [CGDisplayStream.showCursor as String: true] as CFDictionary

        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: streamProps,
            queue: queue,
            handler: { [weak self] status, _, frameSurface, _ in
                guard let self = self else { return }
                if status == .stopped {
                    // Releasing a CGDisplayStream before this callback is
                    // documented as unsafe; the stop path waits for it.
                    self.releaseFallbackDisplayStream()
                    return
                }
                // .frameBlank means the display blanked but the IOSurface is
                // still delivered — encoding it ships a black frame.
                guard status == .frameComplete, let surface = frameSurface else { return }

                var unmanagedPB: Unmanaged<CVPixelBuffer>?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
                let cvReturn = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    surface,
                    attrs as CFDictionary,
                    &unmanagedPB
                )

                guard cvReturn == kCVReturnSuccess, let pb = unmanagedPB?.takeRetainedValue() else { return }

                // Use CMClock for accurate timestamps instead of raw Mach time
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.encoder?.encode(pixelBuffer: pb, presentationTimeStamp: pts)
            }
        ) else {
            debugLog("Failed to create CGDisplayStream — fallback unavailable")
            stateLock.withLock { $0.fallbackActive = false }
            return
        }

        let startResult = displayStream.start()
        if startResult == .success {
            sessionLock.withLock { $0.cgDisplayStream = displayStream }
            debugLog("CGDisplayStream fallback started successfully")
            onCaptureMethodChanged?("CGDisplayStream (fallback)")
        } else {
            debugLog("CGDisplayStream.start() failed: \(startResult)")
            stateLock.withLock { $0.fallbackActive = false }
        }
    }

    /// Stops the CGDisplayStream and keeps the reference until its handler has
    /// observed kCGDisplayStreamFrameStatusStopped — releasing before that
    /// callback is documented as unsafe.
    private func stopFallbackDisplayStream(reason: String) {
        let fallback = sessionLock.withLock { state -> CGDisplayStream? in
            guard let stream = state.cgDisplayStream, !state.cgDisplayStreamStopPending else { return nil }
            state.cgDisplayStreamStopPending = true
            return stream
        }
        guard let fallback else { return }
        debugLog("CGDisplayStream.stop() (\(reason)) — holding the stream until its stopped callback")
        fallback.stop()
        // Backstop: never hold a stopped stream open if the callback is lost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.releaseFallbackDisplayStream() else { return }
            debugLog("CGDisplayStream stopped callback never arrived — released on timeout")
        }
    }

    /// Releases the fallback stream reference. Returns true when a release
    /// actually happened (i.e. it was pending).
    @discardableResult
    private func releaseFallbackDisplayStream() -> Bool {
        sessionLock.withLock { state -> Bool in
            guard state.cgDisplayStreamStopPending, state.cgDisplayStream != nil else { return false }
            state.cgDisplayStream = nil
            state.cgDisplayStreamStopPending = false
            return true
        }
    }

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    /// Switch the wire codec. No-op when unchanged. When changed mid-stream,
    /// rebuilds the encoder at the codec's encode size and restarts capture so
    /// SCStream delivers buffers at the (possibly clamped) dimensions. The
    /// client's keyframe-request loop (force, 200 ms interval) bridges the
    /// restart gap — the decoder drops frames until the first new keyframe.
    /// Note: if the CGDisplayStream fallback is active, restartStream() stops
    /// the fallback first — two capture sources feeding one encoder at
    /// different sizes is worse than a brief SCStream gap — and re-enters the
    /// fallback by itself if SCStream still cannot start.
    /// Apply the per-connection negotiation result: stream codec plus the
    /// client's reported decoder ceiling. Rebuilds the encoder mid-session
    /// when either changes the encode setup (a codec switch, or a ceiling
    /// that alters the encode dimensions — issue #41).
    func negotiate(codec newCodec: StreamCodec, clientLimit: (width: Int, height: Int)?) {
        let sizeBefore = encodeSize(for: codec)
        let codecChanged = newCodec != codec
        if codecChanged {
            debugLog("Switching stream codec: \(codec) -> \(newCodec)")
        }
        codec = newCodec
        clientDecodeLimit = clientLimit

        guard encoder != nil else { return }  // not streaming yet; startStreaming will pick both up

        let sizeAfter = encodeSize(for: newCodec)
        guard codecChanged || sizeBefore != sizeAfter else { return }
        if sizeBefore != sizeAfter {
            let limitDesc = clientLimit.map { "\($0.width)x\($0.height)" } ?? "none"
            debugLog("Encode size \(sizeBefore.width)x\(sizeBefore.height) -> \(sizeAfter.width)x\(sizeAfter.height) (client decoder limit: \(limitDesc))")
        }
        rebuildEncoder()
    }

    private func rebuildEncoder() {
        let (width, height) = encodeSize(for: codec)
        let server = currentServer
        let newEncoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: currentBitrateMbps, quality: currentQuality, gamingBoost: currentGamingBoost, frameRate: currentFrameRate, maxBitrateMbps: currentBitrateCapMbps, wireless: pipelineFlags.wireless)
        newEncoder.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }
        newEncoder.requestKeyframe()
        encoder = newEncoder

        restartStream(reason: "codec/limit changed")
    }

    // MARK: - Stop streaming

    func stopStreaming() {
        // Invalidate any in-flight restart (incl. the delayed wake restart) so
        // it cannot resurrect capture after this stop.
        let stoppedGeneration: UInt64 = sessionLock.withLock { state -> UInt64 in
            state.isStreaming = false
            state.restartPendingReason = nil
            state.generation &+= 1
            state.idlePaused = false
            state.idleGeneration &+= 1
            return state.generation
        }

        // Cancel frame flow monitor
        stopFrameMonitor()

        let streamToStop = currentStream
        let queueToDrain = encodeQueue
        currentStreamOutput?.onFrameReceived = nil
        stateLock.withLock { state in
            state.acceptingFrames = false
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
        }

        // Let the display idle-sleep normally again once we stop streaming.
        releaseDisplaySleepAssertion()

        // Stop CGDisplayStream fallback
        let wasFallback = stateLock.withLock { $0.fallbackActive }
        if wasFallback {
            stopFallbackDisplayStream(reason: "stopStreaming")
            debugLog("CGDisplayStream fallback stopped")
        }

        stateLock.withLock { state in
            state.fallbackActive = false
        }
        setRestartAttempted(false)
        unregisterWakeObservers()

        // Stop capture before dropping the encoder and IOSurface-backed cache.
        // Drain both serial queues so callbacks already in flight cannot enqueue
        // work after the resources have been released. A generation guard keeps
        // a rapid restart on this same object from being cleared by stale cleanup.
        Task {
            // Bounded: a hung stopCapture would otherwise strand the whole
            // cleanup, leaking the compression session and the cached buffer.
            await self.stopCapture(streamToStop, label: "stop(gen \(stoppedGeneration))")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sampleHandlerQueue.async { continuation.resume() }
            }

            if let queueToDrain {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queueToDrain.async { continuation.resume() }
                }
            }

            guard self.isStoppedGeneration(stoppedGeneration) else { return }
            self.clearStream(forGeneration: stoppedGeneration)

            self.encoder?.onEncodedFrame = nil
            self.encoder = nil
            self.encodeQueue = nil
            self.currentServer = nil
            self.stateLock.withLock { $0.lastPixelBuffer = nil }
            debugLog("Capture resources released after stop")
        }
    }
}

// MARK: - StreamOutput

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    /// ScreenCaptureKit hands out invalid sample buffers while a stream tears
    /// down, and non-screen output carries no pixels.
    static func shouldDeliver(type: SCStreamOutputType, sampleBuffer: CMSampleBuffer) -> Bool {
        type == .screen && sampleBuffer.isValid
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard Self.shouldDeliver(type: type, sampleBuffer: sampleBuffer) else { return }
        onFrameReceived?(sampleBuffer)
    }
}
