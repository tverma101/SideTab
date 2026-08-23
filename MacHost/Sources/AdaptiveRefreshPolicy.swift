import Foundation

/// Demand-driven capture-rate policy for SideScreen.
///
/// This is intentionally independent of ScreenCaptureKit so the state machine
/// can be tested deterministically. The integration feeds it SCFrameStatus and
/// dirty-rect area ratios, then applies `targetFPS` with
/// `SCStream.updateConfiguration`.
///
/// Design goals:
/// - rise fast when motion becomes visible;
/// - fall slowly enough that UI motion does not visibly flap between rates;
/// - tiny changes (caret/cursor blink) do not keep the stream at 60/120 FPS;
/// - 120 Hz is a validated burst state, not the default simply because the
///   virtual panel advertises 120 Hz;
/// - sustained 60 FPS video settles at 60 rather than burning a 120 FPS path.
struct AdaptiveRefreshPolicy {
    enum Reason: String, Equatable {
        case fixed
        case gaming
        case highCadence
        case highCadenceProbe
        case broadMotion
        case uiMotion
        case lowMotion
        case warm
        case reading
        case idle
        case deepIdle
    }

    struct Decision: Equatable {
        let targetFPS: Int
        let reason: Reason
    }

    private(set) var maxFPS: Int
    private(set) var gamingBoost: Bool
    private(set) var currentFPS: Int

    private var startedAtNs: UInt64?
    private var lastMeaningfulChangeNs: UInt64?
    private var lastBroadChangeNs: UInt64?
    private var broadMotionSinceNs: UInt64?
    private var fastBroadStreak = 0
    private var highCadenceValidatedUntilNs: UInt64 = 0
    private var probeUntilNs: UInt64 = 0
    private var probeCooldownUntilNs: UInt64 = 0
    private var lastRateChangeNs: UInt64 = 0

    // Tuned for a display-streaming workload rather than a game loop.
    private static let tinyChangeRatio = 0.0015       // ~0.15%: caret/cursor-scale changes
    private static let uiChangeRatio = 0.015          // ~1.5%: typing / small UI updates
    private static let broadChangeRatio = 0.18        // large animation/video/scrolling
    private static let fastBroadIntervalNs: UInt64 = 13_500_000 // >~74 Hz validates high cadence
    private static let broadProbeDelayNs: UInt64 = 180_000_000
    private static let probeDurationNs: UInt64 = 350_000_000
    private static let probeCooldownNs: UInt64 = 8_000_000_000
    private static let highCadenceTailNs: UInt64 = 350_000_000
    private static let downwardHoldNs: UInt64 = 250_000_000

    init(maxFPS: Int, gamingBoost: Bool = false, initialFPS: Int? = nil) {
        self.maxFPS = max(1, maxFPS)
        self.gamingBoost = gamingBoost
        self.currentFPS = min(max(1, initialFPS ?? maxFPS), max(1, maxFPS))
    }

    mutating func setGamingBoost(_ enabled: Bool) {
        gamingBoost = enabled
    }

    mutating func setMaxFPS(_ value: Int) {
        maxFPS = max(1, value)
        currentFPS = min(currentFPS, maxFPS)
    }

    /// Feed one ScreenCaptureKit frame observation.
    ///
    /// - Parameters:
    ///   - nowNs: monotonic uptime timestamp.
    ///   - isIdle: true when SCFrameStatus is `.idle`.
    ///   - dirtyRatio: approximate dirty-rect area / frame area, clamped 0...1.
    /// - Returns: desired capture rate after hysteresis.
    mutating func observe(nowNs: UInt64, isIdle: Bool, dirtyRatio: Double) -> Decision {
        let ratio = min(max(dirtyRatio, 0), 1)
        if startedAtNs == nil {
            startedAtNs = nowNs
            lastMeaningfulChangeNs = nowNs
            lastRateChangeNs = nowNs
        }

        let broad = !isIdle && ratio >= Self.broadChangeRatio
        let uiMotion = !isIdle && ratio >= Self.uiChangeRatio
        let lowMotion = !isIdle && ratio >= Self.tinyChangeRatio

        if broad {
            if let lastBroad = lastBroadChangeNs,
               nowNs >= lastBroad,
               nowNs - lastBroad <= Self.fastBroadIntervalNs {
                fastBroadStreak += 1
            } else {
                fastBroadStreak = 0
            }
            lastBroadChangeNs = nowNs
            if broadMotionSinceNs == nil {
                broadMotionSinceNs = nowNs
            }
            lastMeaningfulChangeNs = nowNs

            if fastBroadStreak >= 2, maxFPS > 60 {
                highCadenceValidatedUntilNs = nowNs + Self.highCadenceTailNs
            }
        } else {
            if let lastBroad = lastBroadChangeNs,
               nowNs >= lastBroad,
               nowNs - lastBroad > 120_000_000 {
                broadMotionSinceNs = nil
                fastBroadStreak = 0
            }
            if uiMotion || lowMotion {
                lastMeaningfulChangeNs = nowNs
            }
        }

        // Expire a failed high-cadence probe before considering a new one.
        // Doing this first is important: otherwise sustained 60-FPS broad
        // motion can renew a 120-Hz probe on the exact frame that should end it.
        if probeUntilNs > 0, nowNs >= probeUntilNs {
            if highCadenceValidatedUntilNs <= nowNs {
                probeCooldownUntilNs = nowNs + Self.probeCooldownNs
            }
            probeUntilNs = 0
        }

        // A probe is the only automatic path from 60 -> >60 without Gaming
        // Boost. At 120 capture, real 120-Hz content produces broad dirty frames
        // ~8.3 ms apart and validates. A 60-FPS video produces them ~16.7 ms
        // apart, fails validation, and falls back to 60 with an 8 s cooldown.
        if maxFPS > 60,
           !gamingBoost,
           highCadenceValidatedUntilNs <= nowNs,
           probeUntilNs == 0,
           probeCooldownUntilNs <= nowNs,
           let broadSince = broadMotionSinceNs,
           broad,
           nowNs >= broadSince,
           nowNs - broadSince >= Self.broadProbeDelayNs {
            probeUntilNs = nowNs + Self.probeDurationNs
        }

        let desired: Int
        let reason: Reason

        if gamingBoost {
            if broad && maxFPS > 60 {
                desired = maxFPS
                reason = .gaming
            } else {
                desired = capped(60)
                reason = .gaming
            }
        } else if maxFPS > 60 && highCadenceValidatedUntilNs > nowNs {
            desired = maxFPS
            reason = .highCadence
        } else if maxFPS > 60 && probeUntilNs > nowNs {
            desired = maxFPS
            reason = .highCadenceProbe
        } else if broad {
            desired = capped(60)
            reason = .broadMotion
        } else if uiMotion {
            desired = capped(60)
            reason = .uiMotion
        } else if lowMotion {
            desired = capped(30)
            reason = .lowMotion
        } else {
            let sinceMeaningful = elapsedSince(lastMeaningfulChangeNs, nowNs: nowNs)
            if sinceMeaningful < 750_000_000 {
                desired = capped(60)
                reason = .warm
            } else if sinceMeaningful < 2_000_000_000 {
                desired = capped(30)
                reason = .reading
            } else if sinceMeaningful < 6_000_000_000 {
                desired = capped(15)
                reason = .idle
            } else {
                desired = capped(8)
                reason = .deepIdle
            }
        }

        // Promotions happen immediately. Demotions wait briefly so short gaps
        // in animation/video do not make the capture rate sawtooth visibly.
        if desired < currentFPS,
           nowNs >= lastRateChangeNs,
           nowNs - lastRateChangeNs < Self.downwardHoldNs {
            return Decision(targetFPS: currentFPS, reason: reason)
        }

        if desired != currentFPS {
            currentFPS = desired
            lastRateChangeNs = nowNs
        }
        return Decision(targetFPS: currentFPS, reason: reason)
    }

    private func capped(_ fps: Int) -> Int {
        min(maxFPS, max(1, fps))
    }

    private func elapsedSince(_ timestamp: UInt64?, nowNs: UInt64) -> UInt64 {
        guard let timestamp, nowNs >= timestamp else { return 0 }
        return nowNs - timestamp
    }
}
