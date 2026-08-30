import Foundation

enum ConnectionMode: String, Codable, CaseIterable {
    case usb
    case wireless
}

/// The listener has one TCP port, but the selected mode defines which kind of
/// peer is allowed to use it. USB reverse forwarding arrives as loopback on
/// the Mac; wireless clients arrive on a non-loopback LAN endpoint.
enum ConnectionModeAdmission {
    static func accepts(_ mode: ConnectionMode, peerIsLoopback: Bool) -> Bool {
        switch mode {
        case .usb:
            return peerIsLoopback
        case .wireless:
            return !peerIsLoopback
        }
    }

    static func rejectionMessage(_ mode: ConnectionMode) -> String {
        switch mode {
        case .usb:
            return "USB mode accepts only the ADB-reverse loopback route"
        case .wireless:
            return "Wireless mode accepts only authenticated LAN clients"
        }
    }
}
