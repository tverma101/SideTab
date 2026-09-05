import Foundation

enum PairingURL {
    static func build(host: String, port: UInt16, token: Data, name: String) -> String {
        let tokenStr = base64URLEncode(token)
        var nameAllowed = CharacterSet.urlQueryAllowed
        nameAllowed.remove(charactersIn: "&=?#")
        let nameEncoded = name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? ""

        // The host can override the dedicated control port independently from
        // the video listener. Older QR payloads omitted this field and Android
        // assumed video+1, so only encode it when the effective port differs.
        // This keeps the common/default QR byte-for-byte compatible.
        let configuredControlPort = UserDefaults.standard.integer(forKey: "SideScreen_controlPort")
        let defaultControlPort = port == UInt16.max ? port : port + 1
        let controlPort =
            configuredControlPort in 1...Int(UInt16.max)
                ? UInt16(configuredControlPort)
                : defaultControlPort
        let controlQuery = controlPort == defaultControlPort ? "" : "&c=\(controlPort)"

        return "sidescreen://\(host):\(port)?t=\(tokenStr)&name=\(nameEncoded)\(controlQuery)"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
