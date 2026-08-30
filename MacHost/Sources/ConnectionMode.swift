import Foundation

enum ConnectionMode: String, Codable, CaseIterable {
    case usb
    case wireless

    var displayName: String {
        self == .usb ? "USB" : "Wireless"
    }

    var wireValue: UInt8 {
        self == .usb ? 0 : 1
    }

    init?(wireValue: UInt8) {
        switch wireValue {
        case 0: self = .usb
        case 1: self = .wireless
        default: return nil
        }
    }
}
