import XCTest
@testable import SideScreen

final class AdaptiveRefreshPolicyTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testStaticContentDecaysToSingleDigits() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 120)

        XCTAssertEqual(policy.observe(nowNs: 0, isIdle: true, dirtyRatio: 0).targetFPS, 120)
        XCTAssertEqual(policy.observe(nowNs: 300 * ms, isIdle: true, dirtyRatio: 0).targetFPS, 60)
        XCTAssertEqual(policy.observe(nowNs: 900 * ms, isIdle: true, dirtyRatio: 0).targetFPS, 30)
        XCTAssertEqual(policy.observe(nowNs: 2_500 * ms, isIdle: true, dirtyRatio: 0).targetFPS, 15)
        XCTAssertEqual(policy.observe(nowNs: 6_500 * ms, isIdle: true, dirtyRatio: 0).targetFPS, 8)
    }

    func testTinyCaretLikeDirtyRectsDoNotWakeDeepIdle() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 120)
        _ = policy.observe(nowNs: 0, isIdle: true, dirtyRatio: 0)
        _ = policy.observe(nowNs: 6_500 * ms, isIdle: true, dirtyRatio: 0)

        let decision = policy.observe(
            nowNs: 7_000 * ms,
            isIdle: false,
            dirtyRatio: 0.0005
        )
        XCTAssertEqual(decision.targetFPS, 8)
        XCTAssertEqual(decision.reason, .deepIdle)
    }

    func testTypingSizedChangePromotesToThirty() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 8)
        _ = policy.observe(nowNs: 0, isIdle: true, dirtyRatio: 0)
        _ = policy.observe(nowNs: 6_500 * ms, isIdle: true, dirtyRatio: 0)

        let decision = policy.observe(
            nowNs: 6_600 * ms,
            isIdle: false,
            dirtyRatio: 0.008
        )
        XCTAssertEqual(decision.targetFPS, 30)
        XCTAssertEqual(decision.reason, .lowMotion)
    }

    func testBroadMotionPromotesImmediatelyToSixty() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 8)
        _ = policy.observe(nowNs: 0, isIdle: true, dirtyRatio: 0)
        _ = policy.observe(nowNs: 6_500 * ms, isIdle: true, dirtyRatio: 0)

        let decision = policy.observe(
            nowNs: 6_600 * ms,
            isIdle: false,
            dirtyRatio: 0.4
        )
        XCTAssertEqual(decision.targetFPS, 60)
        XCTAssertEqual(decision.reason, .broadMotion)
    }

    func testSixtyFPSVideoFailsHighCadenceValidationAndReturnsToSixty() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 60)
        var now: UInt64 = 0

        // Sustained broad motion at ~60 Hz eventually opens a short 120-Hz probe.
        var sawProbe = false
        for _ in 0..<40 {
            let decision = policy.observe(nowNs: now, isIdle: false, dirtyRatio: 0.6)
            if decision.reason == .highCadenceProbe {
                sawProbe = true
            }
            now += 17 * ms
        }
        XCTAssertTrue(sawProbe)

        // 60-Hz dirty frames are too far apart to validate >74-Hz source motion.
        let settled = policy.observe(nowNs: now + 400 * ms, isIdle: false, dirtyRatio: 0.6)
        XCTAssertEqual(settled.targetFPS, 60)
        XCTAssertEqual(settled.reason, .broadMotion)
    }

    func testTrueHighCadenceMotionValidatesOneTwentyDuringProbe() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, initialFPS: 60)
        var now: UInt64 = 0

        // Reach the probe using sustained broad 60-Hz observations.
        var probeStarted = false
        for _ in 0..<30 {
            let decision = policy.observe(nowNs: now, isIdle: false, dirtyRatio: 0.7)
            now += 17 * ms
            if decision.reason == .highCadenceProbe {
                probeStarted = true
                break
            }
        }
        XCTAssertTrue(probeStarted)

        // Once capture is probing at 120, three broad ~8-ms updates validate it.
        let d1 = policy.observe(nowNs: now + 8 * ms, isIdle: false, dirtyRatio: 0.7)
        let d2 = policy.observe(nowNs: now + 16 * ms, isIdle: false, dirtyRatio: 0.7)
        let d3 = policy.observe(nowNs: now + 24 * ms, isIdle: false, dirtyRatio: 0.7)

        XCTAssertEqual(d1.targetFPS, 120)
        XCTAssertEqual(d2.targetFPS, 120)
        XCTAssertEqual(d3.targetFPS, 120)
        XCTAssertEqual(d3.reason, .highCadence)
    }

    func testSixtyFPSSessionCapIsAlwaysAuthoritative() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 60, initialFPS: 60)
        var now: UInt64 = 0

        for _ in 0..<20 {
            let decision = policy.observe(nowNs: now, isIdle: false, dirtyRatio: 1.0)
            XCTAssertLessThanOrEqual(decision.targetFPS, 60)
            now += 8 * ms
        }
    }

    func testGamingBoostKeepsAtLeastSixtyAndAllowsMaximumOnBroadMotion() {
        var policy = AdaptiveRefreshPolicy(maxFPS: 120, gamingBoost: true, initialFPS: 120)
        _ = policy.observe(nowNs: 0, isIdle: true, dirtyRatio: 0)

        let quiet = policy.observe(nowNs: 7_000 * ms, isIdle: true, dirtyRatio: 0)
        XCTAssertEqual(quiet.targetFPS, 60)

        let motion = policy.observe(nowNs: 7_100 * ms, isIdle: false, dirtyRatio: 0.5)
        XCTAssertEqual(motion.targetFPS, 120)
    }
}
