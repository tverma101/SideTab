import Foundation
import Darwin

enum LANAddressResolver {
    private struct Candidate {
        let interfaceName: String
        let family: sa_family_t
        let address: String
    }

    /// Returns the best local address for a pairing payload. On dual-stack
    /// Wi-Fi, IPv6 is ordered before IPv4 so a WLAN that filters IPv4 peer TCP
    /// can still reach the Mac; the other usable addresses are embedded as
    /// fallbacks by PairingURL.
    static func preferredHosts() -> [String] {
        interfaceCandidates()
            .sorted { lhs, rhs in
                let lhsRank = (interfaceRank(lhs.interfaceName), familyRank(lhs.family))
                let rhsRank = (interfaceRank(rhs.interfaceName), familyRank(rhs.family))
                if lhsRank.0 != rhsRank.0 { return lhsRank.0 < rhsRank.0 }
                return lhsRank.1 < rhsRank.1
            }
            .map(\.address)
            .reduce(into: []) { result, address in
                if !result.contains(address) { result.append(address) }
            }
    }

    static func primaryHost() -> String? {
        preferredHosts().first
    }

    /// Returns the first usable IPv4 address, preferring the physical `en*`
    /// interface. This remains available for diagnostics and legacy callers.
    static func primaryIPv4() -> String? {
        interfaceCandidates()
            .filter { $0.family == sa_family_t(AF_INET) }
            .sorted { interfaceRank($0.interfaceName) < interfaceRank($1.interfaceName) }
            .first?
            .address
    }

    static func primaryIPv6() -> String? {
        interfaceCandidates()
            .filter { $0.family == sa_family_t(AF_INET6) }
            .sorted { interfaceRank($0.interfaceName) < interfaceRank($1.interfaceName) }
            .first?
            .address
    }

    static func endpoint(host: String, port: UInt16) -> String {
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(authority):\(port)"
    }

    private static func interfaceCandidates() -> [Candidate] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [Candidate] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if (flags & IFF_UP) != 0,
                   (flags & IFF_LOOPBACK) == 0,
                   family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0,
                        NI_NUMERICHOST
                    )
                    if rc == 0, let ip = String(validatingUTF8: host),
                       !isLoopback(ip), !isLinkLocal(ip) {
                        let name = String(cString: cur.pointee.ifa_name)
                        candidates.append(Candidate(interfaceName: name, family: family, address: ip))
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return candidates
    }

    private static func interfaceRank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        // Keep virtual interfaces as a last-resort fallback. A physical LAN
        // address must win when both a VPN and Wi-Fi are present.
        return 2
    }

    private static func familyRank(_ family: sa_family_t) -> Int {
        family == sa_family_t(AF_INET6) ? 0 : 1
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
    }

    static func isLinkLocal(_ ip: String) -> Bool {
        let normalized = ip.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ip.lowercased()
        return normalized.hasPrefix("169.254.") ||
            normalized.hasPrefix("fe8") ||
            normalized.hasPrefix("fe9") ||
            normalized.hasPrefix("fea") ||
            normalized.hasPrefix("feb")
    }
}
