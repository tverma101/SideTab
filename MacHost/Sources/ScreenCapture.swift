import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
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

// MARK: - ScreenCapture

class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var encoder: VideoEncoder?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?
    private var refreshRate: Int = 60
    private var frameRateCap: Int?

    // Thread-safe state for cross-thread access (frame output queue + main queue)
    private let stateLock = OSAllocatedUnfairLock(initialState: FrameMonitorState())

    private struct FrameMonitorState {
        var lastFrameTime: DispatchTime?
        var hasReceivedFirstFrame = false
    }

    private struct KeyframeRequestState {
        var pendingEncoderCreationRequest = false
        var lastKeyframeOrReplayRequestNs: UInt64 = 0
    }
    private let keyframeRequestLock = OSAllocatedUnfairLock(initialState: KeyframeRequestState())
    private static let keyframeRequestThrottleNs: UInt64 = 500_000_000

    // Main-thread-only state
    private var frameMonitorTimer: DispatchSourceTimer?
    private var restartAttempted = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// True between startStreaming and stopStreaming. Guards wake-triggered
    /// restarts from re-enabling capture after a stop.
    private var isStreaming = false
    /// Bumped on every stopStreaming and every restart so a superseded
    /// in-flight restart Task aborts instead of resurrecting capture.
    private var streamGeneration: UInt64 = 0

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

    /// The current Apple Silicon capture/HEVC Main10 path does not produce a
    /// usable stream at the virtual display's 120-FPS request. Keep the
    /// quality experiment live at a stable 60 FPS until a validated 10-bit
    /// 120-FPS encoder path exists; 8-bit/Main remains eligible for 120 FPS.
    private func qualitySafeFrameRate(_ requested: Int) -> Int {
        let expPixelFormat = UserDefaults.standard.string(forKey: "SideScreen_exp_pixelFormat")
        let expProfile = UserDefaults.standard.string(forKey: "SideScreen_exp_profile")
        guard expPixelFormat == "10bit" || expProfile == "main10" else { return requested }
        let capped = min(requested, 60)
        if capped < requested {
            debugLog("10-bit/Main10 cadence capped: " + String(requested) + " -> " + String(capped) + " fps for stable hardware output")
        }
        return capped
    }

    // Encoding pipeline state (captured by frame handler closure)
    private var encodeQueue: DispatchQueue?
    private var pendingEncodes: Int32 = 0
    private let cachedPixelBufferLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?

    private func cachedPixelBufferSnapshot() -> CVPixelBuffer? {
        cachedPixelBufferLock.lock()
        defer { cachedPixelBufferLock.unlock() }
        return lastPixelBuffer
    }

    private func cachePixelBuffer(_ pixelBuffer: CVPixelBuffer?) {
        cachedPixelBufferLock.lock()
        lastPixelBuffer = pixelBuffer
        cachedPixelBufferLock.unlock()
    }

    // Default-on adaptive cadence controller. It consumes ScreenCaptureKit
    // metadata only — no full-frame pixel hashing in the normal path.
    private var adaptiveRefreshController: AdaptiveRefreshController?

    /// Callback when the ScreenCaptureKit capture state changes.
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

        guard let encoder, let cached = cachedPixelBufferSnapshot() else { return }

        let pts = CMTime(
            value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
            timescale: 1_000_000
        )

        guard currentServer?.shouldEncodeNextFrame() ?? true else { return }
        let captureTimestampNs = DispatchTime.now().uptimeNanoseconds
        encodeQueue?.async {
            encoder.encode(
                pixelBuffer: cached,
                presentationTimeStamp: pts,
                captureTimestampNs: captureTimestampNs
            )
        }
    }

    var displayWidth: Int {
        guard let id = virtualDisplayID else { return display?.width ?? 0 }
        return ScreenCapture.physicalSize(for: id).width
    }
    var displayHeight: Int {
        guard let id = virtualDisplayID else { return display?.height ?? 0 }
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
    /// streaming H.264. SCStream scales the capture into this
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
        let id = virtualDisplayID ?? display?.displayID ?? 0
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
    func setupForVirtualDisplay(_ displayID: CGDirectDisplayID, refreshRate: Int = 60, frameRateCap: Int? = nil) async throws {
        self.virtualDisplayID = displayID
        self.refreshRate = refreshRate
        self.frameRateCap = frameRateCap
        try await setupDisplay()
        try await setupStream()
        await MainActor.run { registerWakeObservers() }
    }

    // MARK: - Display wake handling

    /// Restart ScreenCaptureKit after a display wake. Display sleep can tear
    /// down SCStream (SCStreamErrorDomain -3815, "no displays or windows to
    /// capture"); a bounded restart is the only recovery path we expose.
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
        guard stream != nil else { return }
        // A full system wake fires both screensDidWake and didWake —
        // coalesce them into a single restart.
        guard !wakeRestartPending else { return }
        wakeRestartPending = true
        debugLog("Screens woke — scheduling capture restart")
        // Give WindowServer a moment to settle before touching the stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.wakeRestartPending = false
            guard self.stream != nil else { return }
            self.restartStream()
            // A wake-triggered restart must not consume the one-shot budget
            // the frame monitor uses for stall recovery.
            self.restartAttempted = false
        }
    }

    // MARK: - SCShareableContent with timeout

    private func getShareableContentWithTimeout(seconds: Int = 10) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw NSError(domain: "ScreenCapture", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SCShareableContent timed out after \(seconds)s (possible Apple bug FB12114396)"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Display setup

    private func setupDisplay() async throws {
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
                display = virtualDisplay
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return
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

    private func setupStream() async throws {
        guard let display = display, virtualDisplayID != nil else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        // Physical pixels for full Retina sharpness, clamped when H.264 (SCStream scales)
        let (width, height) = encodeSize(for: codec)
        // EXP-FORK: SideScreen_exp_fps caps the capture cadence (e.g. 90) —
        // a stable 90 beats a jittery 120 when the pipeline can't hold 120.
        let expFps = UserDefaults.standard.integer(forKey: "SideScreen_exp_fps")
        let requestedFrameRate = qualitySafeFrameRate(expFps > 0 ? expFps : refreshRate)
        let fps = min(requestedFrameRate, frameRateCap ?? Int.max)

        streamOutput = StreamOutput()

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self] _ in
            guard let self = self else { return }
            debugLog("StreamDelegate error callback — scheduling ScreenCaptureKit restart")
            self.restartStream()
        }
        streamDelegate = delegate

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // The initial configuration and every live adaptive update use the
        // same builder so changing FPS cannot reset color/pixel-format knobs.
        let config = AdaptiveRefreshController.makeStreamConfiguration(
            width: width,
            height: height,
            fps: fps
        )

        let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try scStream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        stream = scStream
        if AdaptiveRefreshController.isEnabled {
            adaptiveRefreshController = AdaptiveRefreshController(
                width: width,
                height: height,
                maxFPS: fps,
                gamingBoost: currentGamingBoost,
                displayBounds: CGDisplayBounds(display.displayID)
            )
            debugLog("Adaptive refresh enabled — session ceiling \(fps)fps")
        } else {
            adaptiveRefreshController = nil
            debugLog("Adaptive refresh disabled — fixed \(fps)fps")
        }
        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps (with delegate)")
    }

    // MARK: - Shared frame handler (used by both startStreaming and restartStream)

    private func configureFrameHandler(label: String) {
        let queue = DispatchQueue(label: "encodeQueue.\(label)", qos: .userInteractive)
        encodeQueue = queue
        pendingEncodes = 0
        cachePixelBuffer(nil)

        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            guard let self = self else { return }

            // Thread-safe update of frame monitor state
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

            // Keep one retained sample buffer even when ScreenCaptureKit marks
            // the frame idle. A client can connect while the display is static;
            // the forced keyframe path must have pixels to replay instead of
            // leaving the tablet on a black surface until the next change.
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                self.cachePixelBuffer(imageBuffer)
            }

            // ScreenCaptureKit already reports idle frames + changed regions.
            // Use that metadata before dither/HDR/hash/encode/network work.
            if self.adaptiveRefreshController?.observe(
                sampleBuffer: sampleBuffer,
                stream: self.stream
            ) == true {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let captureTimestampNs = DispatchTime.now().uptimeNanoseconds

            // Backpressure: skip if encode queue already has 2+ frames pending
            let pending = OSAtomicAdd32(0, &self.pendingEncodes)
            if pending >= 2 {
                return
            }

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
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
                // The old FrameSkipper remains available only for fixed-FPS
                // A/B experiments. Adaptive mode must not SHA-256 entire pixel
                // planes merely to learn information SCK already supplies.
                if FrameSkipper.enabled && self.adaptiveRefreshController == nil {
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
                        toEncode = hdr
                    } else {
                        debugLog("HDRConverter: convert failed — falling back to 8-bit")
                    }
                }
                self.cachePixelBuffer(toEncode)
                // Keep capture admission ahead of VideoToolbox. Once the
                // bounded sender is full, sacrificing this capture opportunity
                // is safe; emitting a P-frame that will later be discarded is
                // not, because it would invalidate the dependency chain.
                if let server = self.currentServer, !server.shouldEncodeNextFrame() {
                    return
                }
                OSAtomicIncrement32(&self.pendingEncodes)
                queue.async {
                    self.encoder?.encode(
                        pixelBuffer: toEncode,
                        presentationTimeStamp: pts,
                        captureTimestampNs: captureTimestampNs
                    )
                    OSAtomicDecrement32(&self.pendingEncodes)
                }
            } else if let cached = self.cachedPixelBufferSnapshot() {
                if let server = self.currentServer, !server.shouldEncodeNextFrame() {
                    return
                }
                let cachedCaptureTimestampNs = DispatchTime.now().uptimeNanoseconds
                OSAtomicIncrement32(&self.pendingEncodes)
                queue.async {
                    self.encoder?.encode(
                        pixelBuffer: cached,
                        presentationTimeStamp: pts,
                        captureTimestampNs: cachedCaptureTimestampNs
                    )
                    OSAtomicDecrement32(&self.pendingEncodes)
                }
            }
        }
    }

    // MARK: - Start streaming

    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false, frameRate: Int = 60, bitrateCapMbps: Int? = nil, frameRateCap: Int? = nil) {
        // Save parameters for potential restart
        currentServer = server
        // EXP-FORK: SideScreen_exp_fps cap applies to the encoder too (rate
        // control must expect the same cadence the capture actually delivers).
        let expFps = UserDefaults.standard.integer(forKey: "SideScreen_exp_fps")
        // A wireless session is hard-capped even if an old experiment knob
        // still requests 90/120 FPS. USB retains the prior exp-fps behavior.
        self.frameRateCap = frameRateCap
        let requestedFrameRate = qualitySafeFrameRate(expFps > 0 ? expFps : frameRate)
        let effFrameRate = min(requestedFrameRate, frameRateCap ?? Int.max)
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        currentFrameRate = effFrameRate
        currentBitrateCapMbps = bitrateCapMbps
        adaptiveRefreshController?.update(maxFPS: effFrameRate, gamingBoost: gamingBoost)

        isStreaming = true

        // Keep the display awake for the whole streaming session so the virtual
        // display never idle-sleeps (the sleep/wake cycle is what strands the
        // cursor — see the wake handling above for the residual cases).
        createDisplaySleepAssertion()

        let (width, height) = encodeSize(for: codec)

        // EXP-FORK: HDR mode — prepare the 10-bit converter pool + LUTs for the
        // capture size up front (first frame would race the encode otherwise).
        if HDRConverter.enabled {
            HDRConverter.ensureSetup(width: width, height: height)
        }

        encoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost, frameRate: effFrameRate, maxBitrateMbps: bitrateCapMbps)
        encoder?.onEncodedFrame = { [weak server] frame in
            server?.sendFrame(frame)
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
        }

        configureFrameHandler(label: "initial")

        Task {
            do {
                try await stream?.startCapture()
                debugLog("SCStream capture started — starting frame flow monitor (3s interval, 5s timeout)")
                startFrameMonitor()
            } catch {
                debugLog("Failed to start SCStream capture: \(error)")
                onCaptureMethodChanged?("Unavailable — ScreenCaptureKit start failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Continuous frame-flow monitor

    private func startFrameMonitor() {
        stopFrameMonitor()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            let stalled: Bool
            let lastTime = self.stateLock.withLock { $0.lastFrameTime }
            if let last = lastTime {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                stalled = elapsed > 5.0
                if stalled {
                    debugLog("Frame flow stalled — no frames for \(String(format: "%.1f", elapsed))s")
                }
            } else {
                stalled = true
                debugLog("Frame flow stalled — no frames received during the monitor window")
            }

            if stalled {
                let hasHadFrames = self.stateLock.withLock { $0.hasReceivedFirstFrame }

                if hasHadFrames, let lastBuffer = self.cachedPixelBufferSnapshot() {
                    // Screen is idle — SCStream is healthy but not delivering frames (macOS optimization).
                    // Re-send the last captured frame as a keepalive so the tablet stays connected.
                    let pts = CMTime(
                        value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
                        timescale: 1_000_000
                    )
                    if self.currentServer?.shouldEncodeNextFrame() ?? true {
                        let captureTimestampNs = DispatchTime.now().uptimeNanoseconds
                        self.encodeQueue?.async {
                            self.encoder?.encode(
                                pixelBuffer: lastBuffer,
                                presentationTimeStamp: pts,
                                captureTimestampNs: captureTimestampNs
                            )
                        }
                    }
                    self.stateLock.withLock { $0.lastFrameTime = DispatchTime.now() }
                    // Keep monitoring — real errors are handled by the SCStream error delegate
                } else {
                    self.stopFrameMonitor()
                    if !self.restartAttempted {
                        debugLog("Attempting SCStream restart...")
                        self.restartStream()
                    } else {
                        debugLog("Restart already attempted — ScreenCaptureKit capture unavailable")
                        self.onCaptureMethodChanged?("Unavailable — ScreenCaptureKit frame flow stalled")
                    }
                }
            }
        }
        timer.resume()
        frameMonitorTimer = timer
    }

    private func stopFrameMonitor() {
        frameMonitorTimer?.cancel()
        frameMonitorTimer = nil
    }

    // MARK: - Idle sleep (no client connected)

    private(set) var idlePaused = false
    private var idleGeneration = 0

    /// Pause capture+encode while no client is connected — CPU drops to ~0.
    /// Generation-guarded like restartStream so a rapid pause/resume race
    /// cannot strand capture in the wrong state (worst case: a brief extra
    /// stop/start; end state is always "capturing when a client is present").
    /// The frame monitor is stopped so its stall detector does not treat the
    /// intentional pause as a dead stream.
    func pauseForIdle() {
        guard !idlePaused, isStreaming, stream != nil else { return }
        idlePaused = true
        idleGeneration &+= 1
        let gen = idleGeneration
        stopFrameMonitor()
        debugLog("IDLE: pausing capture (no client)")
        Task {
            try? await stream?.stopCapture()
            guard isStreaming, idlePaused, gen == idleGeneration else {
                if isStreaming {
                    // Superseded by a resume — its startCapture may have
                    // landed BEFORE our stopCapture; bring capture back.
                    try? await stream?.startCapture()
                    debugLog("IDLE: pause superseded by resume — capture restored")
                } else {
                    debugLog("IDLE: pause superseded by stop — not bringing capture back")
                }
                return
            }
            debugLog("IDLE: capture paused — CPU sleep")
        }
    }

    /// Resume capture on client connect. The caller forces a keyframe /
    /// replays the cached frame right after, so the client sees pixels
    /// immediately even while the SCStream restarts underneath.
    func resumeFromIdle() {
        guard idlePaused else { return }
        idlePaused = false
        idleGeneration &+= 1
        debugLog("IDLE: resuming capture (client connected)")
        Task {
            try? await stream?.startCapture()
            startFrameMonitor()
            debugLog("IDLE: capture resumed")
        }
    }

    // MARK: - Stream restart

    private func restartStream() {
        guard isStreaming else {
            debugLog("restartStream skipped — not streaming")
            return
        }

        streamGeneration &+= 1
        let gen = streamGeneration
        restartAttempted = true
        stateLock.withLock { $0.hasReceivedFirstFrame = false }

        Task {
            do {
                // Stop existing stream
                try? await stream?.stopCapture()
                // A stopStreaming() or a newer restart superseded this one — do
                // NOT bring capture back up (would resurrect a stopped stream).
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after stopCapture — aborting")
                    return
                }

                stream = nil
                streamOutput = nil
                streamDelegate = nil
                display = nil
                adaptiveRefreshController = nil

                // Re-setup
                try await setupDisplay()
                try await setupStream()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded during setup — aborting")
                    try? await stream?.stopCapture()
                    stream = nil
                    adaptiveRefreshController = nil
                    return
                }

                // Re-attach encoding pipeline using shared handler
                configureFrameHandler(label: "restart")
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded before start — aborting")
                    return
                }

                try await stream?.startCapture()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after startCapture — aborting")
                    try? await stream?.stopCapture()
                    adaptiveRefreshController = nil
                    return
                }

                debugLog("SCStream restarted — starting frame flow monitor")
                startFrameMonitor()
            } catch {
                debugLog("SCStream restart failed: \(error)")
                if isStreaming, gen == streamGeneration {
                    onCaptureMethodChanged?("Unavailable — ScreenCaptureKit restart failed: \(error.localizedDescription)")
                } else {
                    debugLog("restartStream(gen \(gen)) superseded before failure report — aborted")
                }
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
        let reason = "Side Screen is streaming to an external tablet display" as CFString
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

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        adaptiveRefreshController?.update(maxFPS: currentFrameRate, gamingBoost: gamingBoost)
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    /// Switch the wire codec. No-op when unchanged. When changed mid-stream,
    /// rebuilds the encoder at the codec's encode size and restarts capture so
    /// SCStream delivers buffers at the (possibly clamped) dimensions. The
    /// client's keyframe-request loop (force, 200 ms interval) bridges the
    /// restart gap — the decoder drops frames until the first new keyframe.
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
        let newEncoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: currentBitrateMbps, quality: currentQuality, gamingBoost: currentGamingBoost, frameRate: currentFrameRate, maxBitrateMbps: currentBitrateCapMbps)
        newEncoder.onEncodedFrame = { [weak server] frame in
            server?.sendFrame(frame)
        }
        newEncoder.requestKeyframe()
        encoder = newEncoder

        restartStream()
    }

    // MARK: - Stop streaming

    func stopStreaming() {
        // Invalidate any in-flight restart (incl. the delayed wake restart) so
        // it cannot resurrect capture after this stop.
        isStreaming = false
        streamGeneration &+= 1

        // Cancel frame flow monitor and adaptive cadence watchdog.
        stopFrameMonitor()
        adaptiveRefreshController = nil

        // Let the display idle-sleep normally again once we stop streaming.
        releaseDisplaySleepAssertion()

        // Stop SCStream
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                debugLog("Failed to stop SCStream capture: \(error)")
            }
        }

        // Reset state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
        }
        restartAttempted = false
        unregisterWakeObservers()
    }
}

// MARK: - StreamOutput

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onFrameReceived?(sampleBuffer)
    }
}
