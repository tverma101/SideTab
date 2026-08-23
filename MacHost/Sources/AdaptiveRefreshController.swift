import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Runtime bridge between ScreenCaptureKit metadata and AdaptiveRefreshPolicy.
///
/// The controller deliberately avoids reading pixel planes. ScreenCaptureKit
/// already tells us whether a frame is idle and which rectangles changed; that
/// metadata is enough to decide whether 8, 15, 30, 60, or a short >60-FPS
/// probe is justified.
final class AdaptiveRefreshController {
    private struct Observation {
        let isIdle: Bool
        let dirtyRatio: Double
    }

    private let lock = NSLock()
    private let width: Int
    private let height: Int
    private var policy: AdaptiveRefreshPolicy
    private var appliedFPS: Int
    private var desiredFPS: Int
    private var desiredReason: AdaptiveRefreshPolicy.Reason = .warm
    private var updateInFlight = false
    private var lastObservationNs: UInt64 = 0
    private weak var currentStream: SCStream?
    private var idleTimer: DispatchSourceTimer?
    private var inputMonitor: Any?

    /// Default-on. Set `SideScreen_adaptiveRefresh = false` to get the old
    /// fixed-FPS behavior for A/B debugging.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if let explicit = defaults.object(forKey: "SideScreen_adaptiveRefresh") as? NSNumber {
            return explicit.boolValue
        }
        return true
    }

    init(width: Int, height: Int, maxFPS: Int, gamingBoost: Bool) {
        self.width = width
        self.height = height
        let safeMax = max(1, maxFPS)
        self.policy = AdaptiveRefreshPolicy(
            maxFPS: safeMax,
            gamingBoost: gamingBoost,
            initialFPS: safeMax
        )
        self.appliedFPS = safeMax
        self.desiredFPS = safeMax
        installInputMonitor()
    }

    deinit {
        idleTimer?.cancel()
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
        }
    }

    func update(maxFPS: Int, gamingBoost: Bool) {
        lock.lock()
        policy.setMaxFPS(maxFPS)
        policy.setGamingBoost(gamingBoost)
        desiredFPS = min(desiredFPS, max(1, maxFPS))
        lock.unlock()
    }

    /// Feed one sample buffer. Returns true for ScreenCaptureKit `.idle`
    /// buffers, which the caller can drop before image processing/encoding.
    @discardableResult
    func observe(sampleBuffer: CMSampleBuffer, stream: SCStream?) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let observation = Self.observation(from: sampleBuffer)

        lock.lock()
        lastObservationNs = now
        if let stream {
            currentStream = stream
        }
        let decision = policy.observe(
            nowNs: now,
            isIdle: observation.isIdle,
            dirtyRatio: observation.dirtyRatio
        )
        lock.unlock()

        ensureIdleTimer()
        request(decision, stream: stream)
        return observation.isIdle
    }

    /// Pre-wake from user input before an 8/15-FPS ScreenCaptureKit cadence has
    /// a chance to add visible latency. Scroll/drag is continuous motion and
    /// gets the session ceiling; keys/clicks get up to 60 FPS. Plain mouse
    /// movement is intentionally excluded so moving a cursor on another Mac
    /// display cannot keep SideScreen at 120 FPS indefinitely.
    private func installInputMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let token = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleInput(event)
            }
            self.lock.lock()
            self.inputMonitor = token
            self.lock.unlock()
        }
    }

    private func handleInput(_ event: NSEvent) {
        let highRate: Bool
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            highRate = true
        default:
            highRate = false
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let stream = currentStream
        let decision = policy.noteInteraction(nowNs: now, highRate: highRate)
        lock.unlock()
        request(decision, stream: stream)
    }

    /// ScreenCaptureKit can stop producing buffers entirely on an unchanged
    /// desktop. A 4-Hz watchdog advances only the *policy clock* after 250 ms
    /// of silence so the capture rate can still decay 60 -> 30 -> 15 -> 8.
    /// It does not inspect pixels and remains dormant while normal frames flow.
    private func ensureIdleTimer() {
        lock.lock()
        if idleTimer != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        idleTimer = timer
        lock.unlock()

        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.idleTick()
        }
        timer.resume()
    }

    private func idleTick() {
        let now = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        guard lastObservationNs > 0,
              now >= lastObservationNs,
              now - lastObservationNs >= 250_000_000 else {
            lock.unlock()
            return
        }
        let stream = currentStream
        let decision = policy.observe(nowNs: now, isIdle: true, dirtyRatio: 0)
        lock.unlock()

        request(decision, stream: stream)
    }

    private func request(_ decision: AdaptiveRefreshPolicy.Decision, stream: SCStream?) {
        guard let stream else { return }

        var shouldApply = false
        lock.lock()
        desiredFPS = decision.targetFPS
        desiredReason = decision.reason
        if !updateInFlight && desiredFPS != appliedFPS {
            updateInFlight = true
            shouldApply = true
        }
        lock.unlock()

        if shouldApply {
            applyNext(on: stream)
        }
    }

    /// Serializes live `updateConfiguration` calls. A new desired tier that
    /// arrives while an update is in flight is coalesced and applied next.
    private func applyNext(on stream: SCStream) {
        let target: Int
        let reason: AdaptiveRefreshPolicy.Reason
        lock.lock()
        target = desiredFPS
        reason = desiredReason
        lock.unlock()

        let config = Self.makeStreamConfiguration(width: width, height: height, fps: target)
        stream.updateConfiguration(config) { [weak self, weak stream] error in
            guard let self else { return }

            if let error {
                self.lock.lock()
                self.updateInFlight = false
                self.lock.unlock()
                debugLog("Adaptive refresh update to \(target)fps failed: \(error.localizedDescription)")
                return
            }

            self.lock.lock()
            let old = self.appliedFPS
            self.appliedFPS = target
            let needsAnotherUpdate = self.desiredFPS != target
            if !needsAnotherUpdate {
                self.updateInFlight = false
            }
            self.lock.unlock()

            if old != target {
                debugLog("Adaptive refresh: \(old) -> \(target) fps (\(reason.rawValue))")
            }

            if needsAnotherUpdate, let stream {
                self.applyNext(on: stream)
            }
        }
    }

    /// Single source of truth for the initial SCStream configuration and every
    /// adaptive FPS update. Keeping all non-FPS properties identical prevents
    /// `updateConfiguration` from accidentally resetting image quality knobs.
    static func makeStreamConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        let expPixelFormat = UserDefaults.standard.string(forKey: "SideScreen_exp_pixelFormat")
        config.pixelFormat = expPixelFormat == "10bit"
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        switch UserDefaults.standard.string(forKey: "SideScreen_exp_colorSpace") {
        case "displayP3":
            config.colorSpaceName = "kCGColorSpaceDisplayP3" as CFString
        case "bt2020":
            config.colorSpaceName = "kCGColorSpaceITUR_2020" as CFString
        case "srgb":
            config.colorSpaceName = "kCGColorSpaceSRGB" as CFString
        default:
            break
        }

        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false
        return config
    }

    private static func observation(from sampleBuffer: CMSampleBuffer) -> Observation {
        guard let attachments =
                (CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ) as? [[SCStreamFrameInfo: Any]])?.first else {
            // Metadata unavailable: preserve quality rather than guessing idle.
            return Observation(isIdle: false, dirtyRatio: 1)
        }

        let statusRaw: Int? = {
            if let value = attachments[.status] as? Int { return value }
            if let value = attachments[.status] as? NSNumber { return value.intValue }
            return nil
        }()
        let status = statusRaw.flatMap { SCFrameStatus(rawValue: $0) }
        let isIdle = status == .idle

        var rects: [CGRect] = []
        if let values = attachments[.dirtyRects] as? [CGRect] {
            rects = values
        } else if let values = attachments[.dirtyRects] as? [NSValue] {
            rects = values.map { $0.rectValue }
        }

        let frameArea: Double = {
            if let rect = attachments[.contentRect] as? CGRect,
               rect.width > 0, rect.height > 0 {
                return Double(rect.width * rect.height)
            }
            if let value = attachments[.contentRect] as? NSValue {
                let rect = value.rectValue
                if rect.width > 0, rect.height > 0 {
                    return Double(rect.width * rect.height)
                }
            }
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                return Double(CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer))
            }
            return Double(max(1, widthFallback(sampleBuffer)) * max(1, heightFallback(sampleBuffer)))
        }()

        if isIdle {
            return Observation(isIdle: true, dirtyRatio: 0)
        }

        guard !rects.isEmpty, frameArea > 0 else {
            // If a framework/OS version omits dirty rects, stay conservative:
            // treat the frame as broad motion so adaptive refresh cannot hurt
            // visual correctness.
            return Observation(isIdle: false, dirtyRatio: 1)
        }

        let dirtyArea = rects.reduce(0.0) { partial, rect in
            partial + Double(max(0, rect.width) * max(0, rect.height))
        }
        return Observation(isIdle: false, dirtyRatio: min(max(dirtyArea / frameArea, 0), 1))
    }

    private static func widthFallback(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 1 }
        return Int(CMVideoFormatDescriptionGetDimensions(format).width)
    }

    private static func heightFallback(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 1 }
        return Int(CMVideoFormatDescriptionGetDimensions(format).height)
    }
}
