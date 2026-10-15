import XCTest
@testable import SideScreen

final class EncoderGOPPolicyTests: XCTestCase {
    func testLegacyUSBThirtyAndSixtyKeepOneSecondSafetyGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 30,
                adaptiveUSBEnabled: true
            ),
            1
        )
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 60,
                adaptiveUSBEnabled: true
            ),
            1
        )
    }

    func testAdaptiveHighRefreshUSBUsesFiveSecondSafetyGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 90,
                adaptiveUSBEnabled: true
            ),
            5
        )
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 120,
                adaptiveUSBEnabled: true
            ),
            5
        )
    }

    func testExplicitlyDisabledAdaptiveUSBKeepsLegacyOneSecondGOP() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: false,
                frameRate: 120,
                adaptiveUSBEnabled: false
            ),
            1
        )
    }

    /// Wi-Fi takes its routine keyframe when motion stops, so the periodic
    /// fallback only covers long unbroken motion. It must stay inside the
    /// Android wireless stale-keyframe watchdog (32 s).
    func testWirelessUsesLongSafetyGOPBehindIdleKeyframes() {
        XCTAssertEqual(
            EncoderGOPPolicy.safetySeconds(
                isWireless: true,
                frameRate: 60,
                adaptiveUSBEnabled: false
            ),
            30
        )
        XCTAssertLessThan(
            EncoderGOPPolicy.wirelessIdleKeyframeMinAgeNs,
            UInt64(EncoderGOPPolicy.wirelessSafetySeconds) * 1_000_000_000
        )
    }

    /// Every routine IDR is a 430-880 KB burst that comes out softer than the
    /// refined still picture, so the idle keyframe stays rare: well past the
    /// old five-second cadence, just ahead of the periodic fallback.
    func testWirelessIdleKeyframeIsRare() {
        XCTAssertGreaterThanOrEqual(EncoderGOPPolicy.wirelessIdleKeyframeMinAgeNs, 20_000_000_000)
    }
}
