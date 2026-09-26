import Foundation

enum PairingURL {
    /// Reserved characters in a query component. `+` is escaped along with the
    /// rest: it is in `urlQueryAllowed`, and Android's `getQueryParameter`
    /// decodes it as a space, so `Bob's 100% + Mac` used to arrive as
    /// `Bob's 100%   Mac`. The `h=` path only ever carries IP literals, but both
    /// share one set so a future non-literal cannot diverge.
    private static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#+")
        return allowed
    }()

    /// Addresses that parse fine on the client and can never connect. Android
    /// validates the port and the token but not the host, so it persists
    /// whatever is in the QR, resolves it locally, and exhausts its whole retry
    /// ladder against itself before reporting a network failure that points
    /// nowhere near the real problem.
    private static let unpairableHosts: Set<String> = [
        "", "0.0.0.0", "::", "::0", "0:0:0:0:0:0:0:0", "127.0.0.1", "::1",
    ]

    /// nil when the host cannot be paired against, which is the only way this
    /// refuses to produce a payload.
    static func build(
        host: String,
        port: UInt16,
        token: Data,
        name: String,
        alternateHosts: [String] = []
    ) -> String? {
        let primaryHost = normalizedHost(host)
        guard isPairable(primaryHost) else { return nil }

        let tokenStr = base64URLEncode(token)
        let nameEncoded = name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""

        // Preserve legacy QR payloads when control is the conventional video+1.
        // Custom overrides and the UInt16.max boundary are encoded explicitly.
        let controlQuery =
            ControlPortResolver.qrOverride(videoPort: port).map { "&c=\($0)" } ?? ""
        let alternateQuery = alternateHosts
            .map(normalizedHost)
            .filter { isPairable($0) && $0 != primaryHost }
            .reduce(into: [String]()) { result, host in
                if !result.contains(host) { result.append(host) }
            }
            .map { "&h=\(queryEncode($0))" }
            .joined()

        return "sidescreen://\(authorityHost(primaryHost)):\(port)?t=\(tokenStr)&name=\(nameEncoded)\(controlQuery)\(alternateQuery)"
    }

    static func isPairable(_ host: String) -> Bool {
        !unpairableHosts.contains(normalizedHost(host).lowercased())
    }

    private static func normalizedHost(_ host: String) -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func authorityHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private static func queryEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
