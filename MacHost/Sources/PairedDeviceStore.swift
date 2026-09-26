import Foundation
import os

struct PairedDevice: Codable, Equatable, Identifiable {
    /// Stable row identity. Names are not unique — two tablets can both report
    /// the Android default — and `ForEach` needs an id that is both unique and
    /// stable, so it cannot be the name.
    let id: String
    let name: String
    let lastConnected: Date

    init(id: String = UUID().uuidString, name: String, lastConnected: Date) {
        self.id = id
        self.name = name
        self.lastConnected = lastConnected
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lastConnected
    }

    /// Rows persisted before ids existed. The fallback is derived from the rest
    /// of the row so repeated reads of the same stored blob keep matching it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        lastConnected = try container.decode(Date.self, forKey: .lastConnected)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "\(name)@\(Int(lastConnected.timeIntervalSince1970))"
    }
}

final class PairedDeviceStore {
    static let userDefaultsKey = "wireless.pairedDevices"
    /// The list is bounded because its contents are attacker-influenceable: the
    /// pairing handshake accepts a device name, so anyone holding the token can
    /// append a row per handshake. Unbounded, the rows render inside the
    /// settings ScrollView and the stored JSON grows until the panel is unusable.
    static let maxEntries = 8

    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock(initialState: ())

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [PairedDevice] {
        lock.withLock { load() }
    }

    func upsert(name: String, lastConnected: Date) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            var current = load()
            // The handshake carries only a name, so a name match is the closest
            // thing to a device identity available here. Reusing the row keeps
            // its id, and so its place in the list, stable across reconnects.
            if let index = current.firstIndex(where: { $0.name == trimmed }) {
                current[index] = PairedDevice(id: current[index].id, name: trimmed, lastConnected: lastConnected)
            } else {
                current.append(PairedDevice(name: trimmed, lastConnected: lastConnected))
            }
            save(Self.capped(current))
        }
    }

    func forget(id: String) {
        lock.withLock {
            save(load().filter { $0.id != id })
        }
    }

    /// Retained for callers that only know the device name. Names are not unique,
    /// so this removes every row carrying that name.
    func forget(name: String) {
        lock.withLock {
            save(load().filter { $0.name != name })
        }
    }

    func clear() {
        lock.withLock {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        }
    }

    private func load() -> [PairedDevice] {
        guard let data = defaults.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return Self.capped(decoded.sorted { $0.lastConnected > $1.lastConnected })
    }

    /// An encode failure keeps the previous blob. Writing an empty array instead
    /// would read back as "nothing paired" and silently forget every device.
    private func save(_ devices: [PairedDevice]) {
        guard let encoded = try? JSONEncoder().encode(devices) else { return }
        defaults.set(encoded, forKey: Self.userDefaultsKey)
    }

    /// Keeps the most recently connected rows and drops the rest.
    private static func capped(_ devices: [PairedDevice]) -> [PairedDevice] {
        guard devices.count > maxEntries else { return devices }
        return devices.sorted { $0.lastConnected > $1.lastConnected }.prefix(maxEntries).map { $0 }
    }
}
