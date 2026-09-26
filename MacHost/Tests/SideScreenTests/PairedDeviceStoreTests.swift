import XCTest
@testable import SideScreen

final class PairedDeviceStoreTests: XCTestCase {
    private func freshStore() -> PairedDeviceStore {
        let suite = "PairedDeviceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PairedDeviceStore(defaults: defaults)
    }

    func testStartsEmpty() {
        XCTAssertEqual(freshStore().all().count, 0)
    }

    func testUpsertAdds() {
        let store = freshStore()
        store.upsert(name: "iPad Air", lastConnected: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "iPad Air")
    }

    func testUpsertUpdatesExisting() {
        let store = freshStore()
        store.upsert(name: "iPad Air", lastConnected: Date(timeIntervalSince1970: 1000))
        store.upsert(name: "iPad Air", lastConnected: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.lastConnected.timeIntervalSince1970, 2000)
    }

    func testForgetRemoves() {
        let store = freshStore()
        store.upsert(name: "iPad Air", lastConnected: Date())
        store.upsert(name: "Pixel Tablet", lastConnected: Date())
        store.forget(name: "iPad Air")
        XCTAssertEqual(store.all().map { $0.name }, ["Pixel Tablet"])
    }

    func testClearRemovesAll() {
        let store = freshStore()
        store.upsert(name: "iPad Air", lastConnected: Date())
        store.upsert(name: "Pixel Tablet", lastConnected: Date())
        store.clear()
        XCTAssertEqual(store.all().count, 0)
    }

    func testSortedByLastConnectedDescending() {
        let store = freshStore()
        store.upsert(name: "Old", lastConnected: Date(timeIntervalSince1970: 1000))
        store.upsert(name: "New", lastConnected: Date(timeIntervalSince1970: 9000))
        store.upsert(name: "Mid", lastConnected: Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(store.all().map { $0.name }, ["New", "Mid", "Old"])
    }

    func testRoundTripJSON() {
        let suite = "PairedDeviceStoreTests-RT-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let storeA = PairedDeviceStore(defaults: defaults)
        storeA.upsert(name: "iPad Air", lastConnected: Date(timeIntervalSince1970: 1000))
        let storeB = PairedDeviceStore(defaults: defaults)
        XCTAssertEqual(storeB.all().first?.name, "iPad Air")
    }

    /// A handshake carries an attacker-supplied name, so an unbounded list is a
    /// denial of service on the settings panel and on the stored blob.
    func testListIsCappedAndEvictsLeastRecentlyConnected() {
        let store = freshStore()
        let total = PairedDeviceStore.maxEntries + 10
        for index in 0..<total {
            store.upsert(name: "Device \(index)", lastConnected: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let devices = store.all()
        XCTAssertEqual(devices.count, PairedDeviceStore.maxEntries)
        XCTAssertFalse(devices.contains { $0.name == "Device 0" }, "oldest row must be evicted first")
        XCTAssertEqual(devices.first?.name, "Device \(total - 1)", "newest row must be kept")
        XCTAssertEqual(devices.last?.name, "Device \(total - PairedDeviceStore.maxEntries)")
    }

    func testIdsAreUniqueAndStableAcrossUpserts() {
        let store = freshStore()
        store.upsert(name: "iPad", lastConnected: Date(timeIntervalSince1970: 1000))
        let first = store.all().first?.id
        XCTAssertNotNil(first)
        store.upsert(name: "iPad", lastConnected: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.all().first?.id, first, "a reconnect must reuse the row, not mint a new one")
        store.upsert(name: "Pixel", lastConnected: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(Set(store.all().map { $0.id }).count, store.all().count)
    }

    func testForgetByIDRemovesOnlyThatRow() throws {
        let store = freshStore()
        store.upsert(name: "iPad", lastConnected: Date(timeIntervalSince1970: 1000))
        store.upsert(name: "Pixel", lastConnected: Date(timeIntervalSince1970: 2000))
        let devices = store.all()
        let target = try XCTUnwrap(devices.first { $0.name == "Pixel" })
        store.forget(id: target.id)
        XCTAssertEqual(store.all().map { $0.name }, ["iPad"])
    }

    func testBlankNameIsNotPersisted() {
        let store = freshStore()
        store.upsert(name: "   ", lastConnected: Date())
        XCTAssertEqual(store.all().count, 0)
    }

    /// Blobs written before rows carried an id still decode, and keep matching
    /// the same row across reads so the view's ForEach identity is stable.
    func testLegacyRowsWithoutIDsDecode() throws {
        let suite = "PairedDeviceStoreTests-Legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let legacy = """
        [{"name":"iPad Air","lastConnected":1000},{"name":"Pixel","lastConnected":9000}]
        """
        defaults.set(Data(legacy.utf8), forKey: PairedDeviceStore.userDefaultsKey)

        let store = PairedDeviceStore(defaults: defaults)
        let devices = store.all()
        XCTAssertEqual(devices.map { $0.name }, ["Pixel", "iPad Air"])
        XCTAssertEqual(Set(devices.map { $0.id }).count, 2)
        XCTAssertEqual(store.all().map { $0.id }, devices.map { $0.id })
    }

    /// A blob that cannot be decoded must not be treated as "nothing paired"
    /// and then overwritten with an empty list on the next write.
    func testUndecodableBlobIsNotDestroyedByAFailedRead() throws {
        let suite = "PairedDeviceStoreTests-Corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data("not json".utf8), forKey: PairedDeviceStore.userDefaultsKey)
        let store = PairedDeviceStore(defaults: defaults)
        XCTAssertEqual(store.all().count, 0)
        XCTAssertEqual(
            defaults.data(forKey: PairedDeviceStore.userDefaultsKey),
            Data("not json".utf8),
            "reading must not rewrite the stored blob"
        )
    }
}
