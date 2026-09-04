import Foundation
import Security

enum WirelessAuth {
    static let userDefaultsKey = "wireless.authToken"
    private static let keychainService = "com.sidescreen.app.wireless"
    private static let keychainAccount = "pairing-token"

    static func generateToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    /// Test callers may supply an isolated defaults suite. Production callers use Keychain.
    static func persist(_ token: Data, defaults: UserDefaults? = nil) {
        guard let defaults else {
            let query = keychainQuery()
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = token
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                assertionFailure("Unable to persist wireless pairing token in Keychain")
                return
            }
            return
        }
        defaults.set(token, forKey: userDefaultsKey)
    }

    /// Production migration reads the legacy defaults value once, then removes it.
    static func load(defaults: UserDefaults? = nil) -> Data? {
        if let defaults {
            return defaults.data(forKey: userDefaultsKey)
        }
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           data.count == 32 {
            return data
        }

        guard let legacy = UserDefaults.standard.data(forKey: userDefaultsKey), legacy.count == 32 else {
            return nil
        }
        persist(legacy)
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        return legacy
    }

    static func loadOrCreate(defaults: UserDefaults? = nil) -> Data {
        if let existing = load(defaults: defaults), existing.count == 32 {
            return existing
        }
        let fresh = generateToken()
        persist(fresh, defaults: defaults)
        return fresh
    }

    @discardableResult
    static func reset(defaults: UserDefaults? = nil) -> Data {
        if let defaults {
            defaults.removeObject(forKey: userDefaultsKey)
        } else {
            SecItemDelete(keychainQuery() as CFDictionary)
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
        return loadOrCreate(defaults: defaults)
    }

    static func validate(_ candidate: Data, expected: Data) -> Bool {
        guard candidate.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count {
            diff |= candidate[i] ^ expected[i]
        }
        return diff == 0
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}
