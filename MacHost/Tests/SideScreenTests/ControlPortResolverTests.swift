import XCTest
@testable import SideScreen

final class ControlPortResolverTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ControlPortResolverTests")!
        defaults.removePersistentDomain(forName: "ControlPortResolverTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ControlPortResolverTests")
        defaults = nil
        super.tearDown()
    }

    func testDefaultUsesVideoPlusOne() {
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54321, defaults: defaults), 54322)
        XCTAssertNil(ControlPortResolver.qrOverride(videoPort: 54321, defaults: defaults))
    }

    func testExplicitOverrideWinsAndMustBeEncoded() {
        defaults.set(55123, forKey: ControlPortResolver.defaultsKey)
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54321, defaults: defaults), 55123)
        XCTAssertEqual(ControlPortResolver.qrOverride(videoPort: 54321, defaults: defaults), 55123)
    }

    func testExplicitDefaultPortNeedsNoQrExtension() {
        defaults.set(54322, forKey: ControlPortResolver.defaultsKey)
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54321, defaults: defaults), 54322)
        XCTAssertNil(ControlPortResolver.qrOverride(videoPort: 54321, defaults: defaults))
    }

    func testMaximumVideoPortUsesAdjacentPortAndEncodesIt() {
        XCTAssertEqual(ControlPortResolver.effective(videoPort: UInt16.max, defaults: defaults), 65534)
        XCTAssertEqual(ControlPortResolver.qrOverride(videoPort: UInt16.max, defaults: defaults), 65534)
    }

    func testMalformedOverrideFallsBackSafely() {
        defaults.set(70000, forKey: ControlPortResolver.defaultsKey)
        XCTAssertEqual(ControlPortResolver.effective(videoPort: 54321, defaults: defaults), 54322)
    }
}
