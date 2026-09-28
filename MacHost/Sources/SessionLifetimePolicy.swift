import Foundation

/// Bounded session-lifetime contract for the host.
///
/// The macOS host had no disconnect deadline of any kind. `markDisconnected()`
/// was reachable only from the video socket's `.failed`/`.cancelled` state
/// handler, so a client that vanished without a FIN or RST — the normal outcome
/// of a Wi-Fi association dropping — left `settings.clientConnected` stuck true
/// for the life of the process. That single stale flag then disabled every
/// periodic host check: `IdleSleepMonitor` cleared `idleSince` on each tick so
/// capture never paused, `refreshStatusIndicators` early-returned, and the USB
/// checklist never re-probed. The Paired Devices row and the menu-bar indicator
/// both kept rendering a green "Connected" indefinitely.
///
/// This policy owns the "how long may a live session stay silent before the
/// host ends it" decision as a pure function, so it is testable without a
/// socket. Durations are used rather than raw nanoseconds because the deadline
/// must survive system sleep: `DispatchTime.uptimeNanoseconds` maps to
/// `mach_absolute_time`, which stops advancing while the Mac is asleep, and a
/// five-minute wall-clock promise that silently pauses overnight is the exact
/// failure this replaces. `ContinuousClock` is monotonic *and* sleep-inclusive.
enum SessionLifetimePolicy {
    /// A session that receives nothing at all for five minutes is treated as
    /// gone and the host tears it down.
    static let defaultDisconnectTimeout: Duration = .seconds(300)

    /// The watchdog samples well inside the deadline so a session that is alive
    /// right up to the boundary is still ended promptly rather than a full tick
    /// late — and so the check is cheap enough to run continuously.
    static let watchdogTick: Duration = .seconds(5)

    /// `DispatchSourceTimer` schedules in `DispatchTime`, which has no
    /// `Duration` overload. Derived from `watchdogTick` so the timer's cadence
    /// and the tested policy value cannot drift apart.
    static var watchdogTickSeconds: Double {
        let (seconds, attoseconds) = watchdogTick.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Silence is measured from the last byte the *client* sent us, never from
    /// our own sends. The frame sender emits a keepalive encode on a fixed
    /// cadence regardless of whether the peer is reading, so a send-side clock
    /// would be reset forever by writes queued into a dead socket.
    ///
    /// Returns true only when a session is live, has a recorded inbound byte,
    /// and has been silent for at least `timeout`. A session that is not live,
    /// or whose activity has never been stamped, is never ended — the watchdog
    /// is then waiting on an install, not judging a client. A clock reading
    /// earlier than the last activity is not reachable on a monotonic source
    /// but is cheap to guard, and must report "not yet" rather than a false
    /// silence large enough to end a healthy session.
    static func shouldEndSession(
        sessionLive: Bool,
        hasInboundActivity: Bool,
        silence: Duration,
        timeout: Duration = defaultDisconnectTimeout
    ) -> Bool {
        guard sessionLive, hasInboundActivity else { return false }
        guard silence >= .zero else { return false }
        return silence >= timeout
    }
}
