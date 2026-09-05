import CryptoKit
import Foundation

enum WirelessServiceIdentity {
    static let serviceType = "_sidescreen._tcp"

    static func name(for token: Data) -> String {
        precondition(token.count == 32, "pairing token must be 32 bytes")
        let digest = SHA256.hash(data: token)
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "SideScreen-\(suffix)"
    }
}
