import Foundation

enum PairingURL {
    static func build(
        host: String,
        port: UInt16,
        token: Data,
        name: String,
        alternateHosts: [String] = []
    ) -> String {
        let tokenStr = base64URLEncode(token)
        var nameAllowed = CharacterSet.urlQueryAllowed
        nameAllowed.remove(charactersIn: "&=?#")
        let nameEncoded = name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? ""

        // Preserve legacy QR payloads when control is the conventional video+1.
        // Custom overrides and the UInt16.max boundary are encoded explicitly.
        let controlQuery =
            ControlPortResolver.qrOverride(videoPort: port).map { "&c=\($0)" } ?? ""
        let primaryHost = normalizedHost(host)
        let alternateQuery = alternateHosts
            .map(normalizedHost)
            .filter { !$0.isEmpty && $0 != primaryHost }
            .reduce(into: [String]()) { result, host in
                if !result.contains(host) { result.append(host) }
            }
            .map { "&h=\(queryEncode($0))" }
            .joined()

        return "sidescreen://\(authorityHost(primaryHost)):\(port)?t=\(tokenStr)&name=\(nameEncoded)\(controlQuery)\(alternateQuery)"
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
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
