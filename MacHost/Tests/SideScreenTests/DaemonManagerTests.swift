import XCTest
import ServiceManagement
@testable import SideScreen

final class DaemonManagerTests: XCTestCase {
    /// `.requiresApproval` is a registered login item that is waiting on the
    /// user. Reading it as "not registered" snapped the settings toggle off,
    /// re-registered on every launch, and opened the settings window on every
    /// login even though the login item was live.
    func testRequiresApprovalCountsAsRegistered() {
        XCTAssertTrue(DaemonManager.isRegistered(status: .requiresApproval))
        XCTAssertTrue(DaemonManager.isRegistered(status: .enabled))
    }

    func testUnregisteredStatusesAreNotRegistered() {
        XCTAssertFalse(DaemonManager.isRegistered(status: .notRegistered))
        XCTAssertFalse(DaemonManager.isRegistered(status: .notFound))
    }

    func testEveryStatusIsClassified() {
        let statuses: [SMAppService.Status] = [.notRegistered, .enabled, .requiresApproval, .notFound]
        let registered = statuses.filter(DaemonManager.isRegistered(status:))
        XCTAssertEqual(Set(registered), [.enabled, .requiresApproval])
    }
}
