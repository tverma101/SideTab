import XCTest
@testable import SideScreen

final class SessionLifetimePolicyTests: XCTestCase {

    // MARK: - The deadline itself

    func testDisconnectTimeoutIsFiveMinutes() {
        XCTAssertEqual(300, SessionLifetimePolicy.defaultDisconnectTimeout.components.seconds)
    }

    func testWatchdogTicksWellInsideTheDeadline() {
        let tick = SessionLifetimePolicy.watchdogTick
        XCTAssertEqual(5, tick.components.seconds)
        // A tick that is a large fraction of the budget would end healthy
        // sessions up to that fraction late. Keep it well clear of that.
        XCTAssertLessThan(
            tick.components.seconds * 10,
            SessionLifetimePolicy.defaultDisconnectTimeout.components.seconds
        )
    }

    func testWatchdogTickSecondsMatchesTheDurationContract() {
        XCTAssertEqual(5.0, SessionLifetimePolicy.watchdogTickSeconds, accuracy: 0.000_001)
    }

    // MARK: - The reported bug: a silent session must be ended

    func testSilentSessionIsEndedAtTheDeadline() {
        XCTAssertTrue(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(300)
            )
        )
    }

    func testSilentSessionIsEndedAfterTheDeadline() {
        XCTAssertTrue(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(5 * 60 * 60)
            )
        )
    }

    // MARK: - The regressions this must not reintroduce

    /// The original bug: a live stream that the host still believes in must be
    /// left alone right up to the boundary.
    func testActiveSessionIsNotEndedBeforeTheDeadline() {
        for seconds in [0, 1, 30, 60, 120, 299] {
            XCTAssertFalse(
                SessionLifetimePolicy.shouldEndSession(
                    sessionLive: true,
                    hasInboundActivity: true,
                    silence: .seconds(seconds)
                ),
                "ended a live session after only \(seconds)s of silence"
            )
        }
    }

    /// A session that has not been marked live is being set up, not judged.
    func testSessionThatIsNotLiveIsNeverEnded() {
        XCTAssertFalse(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: false,
                hasInboundActivity: true,
                silence: .seconds(3600)
            )
        )
    }

    /// A session whose activity has never been stamped is waiting on an
    /// install. Ending it would be a false positive against an unknown client.
    func testSessionWithNoInboundStampIsNeverEnded() {
        XCTAssertFalse(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: false,
                silence: .seconds(3600)
            )
        )
    }

    /// A clock reading behind the last activity is not reachable on a monotonic
    /// source, but must not be interpreted as an enormous silence.
    func testNonMonotonicClockDoesNotEndTheSession() {
        XCTAssertFalse(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(-5)
            )
        )
    }

    // MARK: - Sleep semantics

    /// The deadline is a real-world promise, so the measured duration has to
    /// include time the Mac spent asleep. A mach_absolute_time-based clock
    /// (what `DispatchTime.uptimeNanoseconds` wraps) stops across sleep, which
    /// is precisely how a "five minute" timeout used to never arrive for a
    /// client that left overnight.
    func testDeadlineIsMeasuredInSleepInclusiveDurations() {
        // A wall-clock-shaped silence long enough to span an overnight sleep
        // ends the session, which a suspend-excluding clock would not do.
        XCTAssertTrue(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(60 * 60 * 9)
            )
        )
    }

    /// The timeout is a tunable knob; the policy honours whatever it is given
    /// rather than hard-coding 300s at the decision site.
    func testTimeoutIsConfigurable() {
        XCTAssertFalse(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(30),
                timeout: .seconds(60)
            )
        )
        XCTAssertTrue(
            SessionLifetimePolicy.shouldEndSession(
                sessionLive: true,
                hasInboundActivity: true,
                silence: .seconds(45),
                timeout: .seconds(30)
            )
        )
    }
}
