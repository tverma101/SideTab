import Foundation
import Darwin
import os

enum LANAddressResolver {
    struct Candidate: Equatable {
        let interfaceName: String
        let family: sa_family_t
        let address: String
        /// Already present in the previous resolution pass, so it has been up
        /// long enough to be the address a paired tablet can still hold.
        let isEstablished: Bool
    }

    /// Recently seen addresses, used to tell a long-lived address from one that
    /// has just appeared.
    private static let recentAddresses = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    /// How long an address that disappeared keeps its established credit. Well
    /// over the refresh interval, short enough that an address returning after a
    /// long outage is treated as new.
    private static let establishmentTTL: TimeInterval = 60

    /// Returns the best local address for a pairing payload. On dual-stack
    /// Wi-Fi, IPv6 is ordered before IPv4 so a WLAN that filters IPv4 peer TCP
    /// can still reach the Mac; the other usable addresses are embedded as
    /// fallbacks by PairingURL.
    ///
    /// macOS rotates RFC 4941 privacy addresses hourly and on every network
    /// change, and no public API reports IN6_IFF_TEMPORARY — `ifa_data` is NULL
    /// for every AF_INET6 entry and the netlink message structs that carry the
    /// per-address flags are private. What is observable is tenure, so an
    /// address that was already present in the previous pass outranks one that
    /// has just appeared. That keeps the rotating temporary out of the primary
    /// slot (and out of the slot a tablet persists) while it stays a fallback.
    static func preferredHosts() -> [String] {
        rankedCandidates()
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
        rankedCandidates().first { $0.family == sa_family_t(AF_INET) }?.address
    }

    static func primaryIPv6() -> String? {
        rankedCandidates().first { $0.family == sa_family_t(AF_INET6) }?.address
    }

    /// Every candidate, best first. Same ranking as `preferredHosts` but keeps
    /// the interface and tenure information, so callers can explain a choice.
    static func rankedCandidates() -> [Candidate] {
        let now = Date()
        let current = interfaceCandidates()
        let established = recentAddresses.withLock { recorded -> Set<String> in
            var kept = recorded.filter { now.timeIntervalSince($0.value) <= establishmentTTL }
            let previouslySeen = Set(kept.keys)
            for candidate in current where kept[candidate.address] == nil {
                kept[candidate.address] = now
            }
            return previouslySeen
        }
        return current
            .map { candidate in
                Candidate(
                    interfaceName: candidate.interfaceName,
                    family: candidate.family,
                    address: candidate.address,
                    isEstablished: established.contains(candidate.address)
                )
            }
            .sorted { rank($0) < rank($1) }
    }

    /// Lowest sorts first: a physical LAN interface, then the address family the
    /// resolver prefers there, then an address that was already up last pass.
    static func rank(_ candidate: Candidate) -> (Int, Int, Int) {
        (
            interfaceRank(candidate.interfaceName),
            familyRank(candidate.family),
            candidate.isEstablished ? 0 : 1
        )
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
            // ifa_addr is NULL for AF_LINK entries, which carry the hardware
            // address instead of an IP one.
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
                       isPeerReachable(ip) {
                        let name = String(cString: cur.pointee.ifa_name)
                        candidates.append(Candidate(
                            interfaceName: name,
                            family: family,
                            address: ip,
                            isEstablished: false
                        ))
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
        let normalized = unscoped(ip)
        return normalized.hasPrefix("169.254.") ||
            normalized.hasPrefix("fe8") ||
            normalized.hasPrefix("fe9") ||
            normalized.hasPrefix("fea") ||
            normalized.hasPrefix("feb")
    }

    /// Whether a peer on the same link could plausibly open a TCP connection to
    /// this address. Loopback and link-local aside, this rejects the ranges that
    /// are not reachable off-box: `0.0.0.0/8` (including the unspecified
    /// address), carrier-grade NAT `100.64/10` (Tailscale and friends), the
    /// benchmarking block `198.18/15`, and everything from `224.0.0.0` up.
    /// Advertising any of them makes the UI report a working LAN the tablet
    /// cannot route to.
    ///
    /// IPv6 is held to `2000::/3`, the only globally-routed range. That covers
    /// ULA (`fc00::/7`, so `fc00::/8` and `fd00::/8`), the `fe00::/9` hole,
    /// link-local (`fe80::/10`), the deprecated site-local block (`fec0::/10`),
    /// multicast and the unspecified address, and cannot match a legitimate
    /// global address because the top three bits of every one of those start
    /// `111` while `2000::/3` starts `001`.
    static func isPeerReachable(_ ip: String) -> Bool {
        guard !isLoopback(ip), !isLinkLocal(ip) else { return false }
        if let bytes = ipv4Bytes(ip) { return isRoutableIPv4(bytes) }
        guard let bytes = ipv6Bytes(ip) else { return false }
        return bytes[0] & 0xe0 == 0x20
    }

    private static func isRoutableIPv4(_ bytes: [UInt8]) -> Bool {
        if bytes[0] == 0 { return false }                              // 0.0.0.0/8
        if bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127 { return false }   // 100.64/10
        if bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19) { return false } // 198.18/15
        if bytes[0] >= 224 { return false }                            // multicast/reserved
        return true
    }

    private static func ipv4Bytes(_ ip: String) -> [UInt8]? {
        var address = in_addr()
        guard unscoped(ip).withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// The scope suffix is dropped first: `inet_pton` rejects `fe80::1%en0`, and
    /// a link-local address is filtered out anyway.
    private static func ipv6Bytes(_ ip: String) -> [UInt8]? {
        var address = in6_addr()
        let value = unscoped(ip)
        guard value.utf8.count < Int(INET6_ADDRSTRLEN),
              value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func unscoped(_ ip: String) -> String {
        ip.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ip.lowercased()
    }
}
