import Foundation

enum PairingURL {
    static func build(host: String, port: UInt16, token: Data, name: String) -> String {
        let tokenStr = base64URLEncode(token)
        var nameAllowed = CharacterSet.urlQueryAllowed
        nameAllowed.remove(charactersIn: "&=?#")
        let nameEncoded = name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? ""

        // Preserve legacy QR payloads when control is the conventional video+1.
        // Custom overrides and the UInt16.max boundary are encoded explicitly.
        let controlQuery =
            ControlPortResolver.qrOverride(videoPort: port).map { "&c=\($0)" } ?? ""

        return "sidescreen://\(host):\(port)?t=\(tokenStr)&name=\(nameEncoded)\(controlQuery)"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
