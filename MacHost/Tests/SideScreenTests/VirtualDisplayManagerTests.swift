import XCTest
import CoreGraphics
@testable import SideScreen

/// Covers the parts of the virtual-display manager that are pure functions:
/// dimension validation, identity derivation, and the placement geometry the
/// #39 guard and the position restore reason about. Nothing here needs a real
/// display — a live CGVirtualDisplay cannot be created in a test process.
final class VirtualDisplayManagerTests: XCTestCase {
    // MARK: - Geometry limits

    func testLiveCallerSizePassesThroughUnchanged() {
        // The only live caller path: 1400x876 HiDPI is the configuration
        // verified working, and 2800x1752 physical must not move.
        let g = try? VirtualDisplayLimits.resolve(width: 1400, height: 876, refreshRate: 60, hiDPI: true)
        XCTAssertEqual(g?.pointsWide, 1400)
        XCTAssertEqual(g?.pointsHigh, 876)
        XCTAssertEqual(g?.pixelsWide, 2800)
        XCTAssertEqual(g?.pixelsHigh, 1752)
        XCTAssertEqual(g?.refreshRate, 60)
    }

    func testNonHiDPIDoesNotDouble() {
        let g = try? VirtualDisplayLimits.resolve(width: 1920, height: 1080, refreshRate: 60, hiDPI: false)
        XCTAssertEqual(g?.pointsWide, 1920)
        XCTAssertEqual(g?.pixelsHigh, 1080)
        XCTAssertEqual(g?.pixelsWide, 1920)
        XCTAssertEqual(g?.pixelsHigh, 1080)
    }

    /// UInt32(negative) traps with SIGTRAP rather than wrapping, so an
    /// unrepresentable request must throw instead of reaching the conversion.
    func testUnrepresentableSizesThrow() {
        for (w, h) in [(-1, 100), (100, -1), (0, 0), (0, 100), (100, 0), (Int.min, 100)] {
            XCTAssertThrowsError(
                try VirtualDisplayLimits.resolve(width: w, height: h, refreshRate: 60, hiDPI: false),
                "\(w)x\(h) must be rejected"
            ) { error in
                guard case VirtualDisplayError.invalidGeometry = error else {
                    return XCTFail("wrong error for \(w)x\(h): \(error)")
                }
            }
        }
    }

    func testNonPositiveRefreshRateThrows() {
        for rate in [0, -60] {
            XCTAssertThrowsError(
                try VirtualDisplayLimits.resolve(width: 1400, height: 876, refreshRate: rate, hiDPI: false)
            )
        }
    }

    /// The WindowServer rejects a mode larger than the descriptor's maximum, and
    /// the API is bounded at 64..16384. HiDPI caps the LOGICAL size at half so
    /// the doubled physical size still fits and the two modes stay distinct.
    func testOversizedRequestsClampInsideTheAPIBound() {
        let g = try? VirtualDisplayLimits.resolve(width: 20000, height: 10000, refreshRate: 60, hiDPI: true)
        XCTAssertEqual(g?.pointsWide, 8192)
        XCTAssertEqual(g?.pointsHigh, 8192)
        XCTAssertEqual(g?.pixelsWide, 16384)
        XCTAssertEqual(g?.pixelsHigh, 16384)

        // 10000 is inside the bound on its own, so without HiDPI only the
        // oversized axis moves.
        let plain = try? VirtualDisplayLimits.resolve(width: 20000, height: 10000, refreshRate: 60, hiDPI: false)
        XCTAssertEqual(plain?.pixelsWide, 16384)
        XCTAssertEqual(plain?.pixelsHigh, 10000)
    }

    func testTinySizesClampUpToTheMinimum() {
        let g = try? VirtualDisplayLimits.resolve(width: 10, height: 10, refreshRate: 60, hiDPI: false)
        XCTAssertEqual(g?.pixelsWide, 64)
        XCTAssertEqual(g?.pixelsHigh, 64)
    }

    func testRefreshRateClampsInsteadOfBeingSentRaw() throws {
        let fast = try VirtualDisplayLimits.resolve(width: 800, height: 600, refreshRate: 100_000, hiDPI: false)
        XCTAssertEqual(fast.refreshRate, VirtualDisplayLimits.maxRefreshRate)
        let slow = try VirtualDisplayLimits.resolve(width: 800, height: 600, refreshRate: 1, hiDPI: false)
        XCTAssertEqual(slow.refreshRate, VirtualDisplayLimits.minRefreshRate)
    }

    func testEveryResolvedGeometryConvertsToUInt32WithoutTrapping() {
        for (w, h) in [(1, 1), (1400, 876), (16384, 16384), (99999, 3), (3, 99999)] {
            for hiDPI in [false, true] {
                guard let g = try? VirtualDisplayLimits.resolve(width: w, height: h, refreshRate: 60, hiDPI: hiDPI) else {
                    return XCTFail("\(w)x\(h) hiDPI \(hiDPI) unexpectedly threw")
                }
                XCTAssertGreaterThan(g.pixelsWide, 0)
                XCTAssertGreaterThan(g.pixelsHigh, 0)
                XCTAssertLessThanOrEqual(g.pixelsWide, VirtualDisplayLimits.maxDimension)
                XCTAssertLessThanOrEqual(g.pixelsHigh, VirtualDisplayLimits.maxDimension)
            }
        }
    }

    // MARK: - Product ID

    func testProductIDRoundTripsTheLiveValue() {
        XCTAssertEqual(VirtualDisplayLimits.productID(pixelsWide: 2800, pixelsHigh: 1752), 0x1AB45D8)
    }

    func testProductIDSeparatesPortraitFromLandscape() {
        XCTAssertNotEqual(
            VirtualDisplayLimits.productID(pixelsWide: 3840, pixelsHigh: 2400),
            VirtualDisplayLimits.productID(pixelsWide: 2400, pixelsHigh: 3840)
        )
    }

    func testProductIDDoesNotOverflowAtTheLargestAcceptedSize() {
        let largest = VirtualDisplayLimits.productID(
            pixelsWide: VirtualDisplayLimits.maxDimension,
            pixelsHigh: VirtualDisplayLimits.maxDimension
        )
        XCTAssertEqual(
            largest,
            UInt32(VirtualDisplayLimits.maxDimension * 10000 + VirtualDisplayLimits.maxDimension)
        )
    }

    // MARK: - Serial derivation

    private func seed(
        pixelsWide: Int = 2800,
        pixelsHigh: Int = 1752,
        refreshRate: Int = 60,
        hiDPI: Bool = true,
        productIDOverride: UInt32? = nil
    ) -> VirtualDisplaySerial.Seed {
        VirtualDisplaySerial.Seed(
            vendorID: VirtualDisplayManager.vendorID,
            productID: productIDOverride ?? VirtualDisplayLimits.productID(
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh
            ),
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            refreshRate: refreshRate,
            hiDPI: hiDPI
        )
    }

    /// macOS remembers per-display state on (vendor, product, serial), so the
    /// serial must be identical on every run for the same configuration...
    func testSerialIsStableForTheSameConfiguration() {
        XCTAssertEqual(
            VirtualDisplaySerial.number(for: seed()),
            VirtualDisplaySerial.number(for: seed())
        )
    }

    /// ...and different for every distinct configuration, or two SideScreen
    /// displays are the same monitor to the OS.
    func testSerialIsDistinctPerConfiguration() {
        let configurations: [VirtualDisplaySerial.Seed] = [
            seed(),
            seed(pixelsWide: 2800, pixelsHigh: 1752, hiDPI: false),
            seed(pixelsWide: 1920, pixelsHigh: 1080, hiDPI: false),
            seed(pixelsWide: 1400, pixelsHigh: 876, hiDPI: true),
            seed(refreshRate: 120),
            seed(pixelsWide: 3840, pixelsHigh: 2400, hiDPI: true)
        ]
        let serials = configurations.map { VirtualDisplaySerial.number(for: $0) }
        XCTAssertEqual(Set(serials).count, configurations.count, "collision across \(serials)")
    }

    func testSerialIsNeverZero() {
        for (w, h) in [(64, 64), (800, 600), (1400, 876), (3840, 2400), (16384, 16384)] {
            for hiDPI in [false, true] {
                let value = VirtualDisplaySerial.number(for: seed(pixelsWide: w, pixelsHigh: h, hiDPI: hiDPI))
                XCTAssertNotEqual(value, 0, "\(w)x\(h) hiDPI \(hiDPI)")
            }
        }
    }

    // MARK: - Placement geometry

    private let virtualSize = CGSize(width: 1400, height: 876)
    private let laptop = CGRect(x: 0, y: 0, width: 3024, height: 1894)

    /// The #39 arrangement: the saved origin lands on the main slot while a
    /// physical display owns it. The old code special-cased exactly (0,0).
    func testMainSlotOriginIsRejectedWhileAPhysicalDisplayHoldsIt() {
        XCTAssertFalse(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 0, y: 0),
                virtualSize: virtualSize,
                physicalBounds: [laptop]
            )
        )
    }

    func testOriginOverlappingAPhysicalDisplayIsRejected() {
        XCTAssertFalse(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 1000, y: 1000),
                virtualSize: virtualSize,
                physicalBounds: [laptop]
            )
        )
    }

    func testAdjacentOriginsAreAccepted() {
        for origin in [
            CGPoint(x: 3024, y: 0),      // immediately right
            CGPoint(x: 0, y: 1894),      // immediately below
            CGPoint(x: 3024, y: 1894),   // diagonal corner
            CGPoint(x: -1400, y: 0)      // immediately left
        ] {
            XCTAssertTrue(
                VirtualDisplayPlacement.isReachable(
                    savedOrigin: origin,
                    virtualSize: virtualSize,
                    physicalBounds: [laptop]
                ),
                "\(origin) should be reachable"
            )
        }
    }

    /// Two monitors attached when the position was saved, one unplugged since:
    /// the saved origin now floats past the desktop edge, and
    /// CGConfigureDisplayOrigin accepts it without error.
    func testStaleOriginAcrossADisappearedDisplayIsRejected() {
        XCTAssertFalse(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 5000, y: 0),
                virtualSize: virtualSize,
                physicalBounds: [laptop]
            ),
            "the second monitor is gone, so (5000,0) is a gap the user cannot scroll to"
        )
        // The very same origin is adjacent to that monitor while it is attached.
        XCTAssertTrue(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 5000, y: 0),
                virtualSize: virtualSize,
                physicalBounds: [laptop, CGRect(x: 6400, y: 0, width: 2560, height: 1440)]
            )
        )
    }

    func testReachableAgainstAnyAttachedDisplayNotOnlyTheFirst() {
        let second = CGRect(x: 5000, y: 200, width: 2560, height: 1440)
        XCTAssertTrue(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 7560, y: 200),
                virtualSize: virtualSize,
                physicalBounds: [laptop, second]
            )
        )
    }

    func testDegenerateInputsAreNotReachable() {
        XCTAssertFalse(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 0, y: 0),
                virtualSize: virtualSize,
                physicalBounds: []
            ),
            "headless is decided by the caller, not by the reachability test"
        )
        XCTAssertFalse(
            VirtualDisplayPlacement.isReachable(
                savedOrigin: CGPoint(x: 0, y: 0),
                virtualSize: .zero,
                physicalBounds: [laptop]
            )
        )
    }

    // MARK: - Main slot owner

    func testMainSlotOwnerPicksTheDisplayHoldingTheOrigin() {
        let second = CGRect(x: 3024, y: 0, width: 2560, height: 1440)
        // The online list is ascending by display ID, i.e. NOT main-first, so
        // index 0 is not allowed to win by default.
        XCTAssertEqual(VirtualDisplayPlacement.mainSlotOwner(in: [second, laptop]), 1)
        XCTAssertEqual(VirtualDisplayPlacement.mainSlotOwner(in: [laptop, second]), 0)
    }

    func testMainSlotOwnerFallsBackToTheNearestOrigin() {
        // Nothing contains (0,0) — the virtual display is main and the
        // physicals have been pushed right.
        let shifted = [CGRect(x: 4400, y: 0, width: 1920, height: 1200), CGRect(x: 200, y: 300, width: 1920, height: 1200)]
        XCTAssertEqual(VirtualDisplayPlacement.mainSlotOwner(in: shifted), 1)
    }

    func testMainSlotOwnerIsDeterministicOnTies() {
        let tie = [CGRect(x: 0, y: 500, width: 100, height: 100), CGRect(x: 500, y: 0, width: 100, height: 100)]
        XCTAssertEqual(
            VirtualDisplayPlacement.mainSlotOwner(in: tie),
            VirtualDisplayPlacement.mainSlotOwner(in: tie.reversed())
        )
    }

    func testMainSlotOwnerOfNoDisplaysIsNil() {
        XCTAssertNil(VirtualDisplayPlacement.mainSlotOwner(in: []))
    }

    // MARK: - Private API shape

    func testRequiredAPIShapeTableIsWellFormed() {
        XCTAssertFalse(VirtualDisplayManager.apiShape.isEmpty)
        var classes = Set<String>()
        for requirement in VirtualDisplayManager.apiShape {
            XCTAssertTrue(requirement.class.hasPrefix("CGVirtualDisplay"), requirement.class)
            XCTAssertTrue(classes.insert(requirement.class).inserted, "duplicate \(requirement.class)")
            XCTAssertFalse(requirement.selectors.isEmpty, requirement.class)
            for selector in requirement.selectors {
                // Setters take an argument; displayID is the one getter the
                // manager reads back off the display.
                XCTAssertTrue(
                    selector.hasSuffix(":") || selector == "displayID",
                    "\(requirement.class).\(selector)"
                )
            }
        }
        XCTAssertTrue(classes.contains("CGVirtualDisplay"))
        XCTAssertTrue(classes.contains("CGVirtualDisplayDescriptor"))
        XCTAssertTrue(classes.contains("CGVirtualDisplaySettings"))
        XCTAssertTrue(classes.contains("CGVirtualDisplayMode"))
    }

    /// The check itself may legitimately fail on a macOS that reshaped the
    /// private API, but it must never fail with anything else — that is the
    /// whole point of turning a launch crash into a disabled feature.
    func testAPIShapeCheckOnlyEverReportsUnsupportedOS() throws {
        do {
            try VirtualDisplayManager.verifyAPIShape()
        } catch let error as VirtualDisplayError {
            guard case .unsupportedOS(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Errors

    func testNewErrorCasesDescribeThemselves() {
        XCTAssertTrue(
            VirtualDisplayError.invalidGeometry("width and height must be positive").localizedDescription
                .contains("width and height must be positive")
        )
        XCTAssertTrue(
            VirtualDisplayError.unsupportedOS("CGVirtualDisplay is unavailable").localizedDescription
                .contains("CGVirtualDisplay is unavailable")
        )
    }
}
