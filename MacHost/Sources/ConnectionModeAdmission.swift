import Foundation

/// Mode admission is intentionally pure so the Android/macOS bridge contract
/// can be tested without opening listeners or requiring a real tablet.
enum ConnectionModeAdmission {
    static let clientHelloType: UInt8 = 16
    static let serverResultType: UInt8 = 17
    private static let payloadMarker: UInt8 = 0x80

    enum ResultCode: UInt8 {
        case accepted = 0
        case wrongMode = 1
        case wrongTransport = 2
        case invalidHello = 3
    }

    struct ServerResult: Equatable {
        let code: ResultCode
        let expectedMode: ConnectionMode

        var accepted: Bool { code == .accepted }
    }

    static func encodeClientHello(mode: ConnectionMode) -> Data {
        Data([clientHelloType, payloadMarker | mode.wireValue])
    }

    static func decodeClientHello(type: UInt8, payload: UInt8) -> ConnectionMode? {
        guard type == clientHelloType, payload & payloadMarker != 0 else { return nil }
        return ConnectionMode(wireValue: payload & ~payloadMarker)
    }

    static func encodeServerResult(code: ResultCode, expectedMode: ConnectionMode) -> Data {
        Data([serverResultType, code.rawValue, payloadMarker | expectedMode.wireValue])
    }

    static func decodeServerResult(_ data: Data) -> ServerResult? {
        guard data.count == 3,
              data[data.startIndex] == serverResultType,
              let code = ResultCode(rawValue: data[data.index(data.startIndex, offsetBy: 1)]),
              let expectedMode = ConnectionMode(
                  wireValue: data[data.index(data.startIndex, offsetBy: 2)] & ~payloadMarker
              ),
              data[data.index(data.startIndex, offsetBy: 2)] & payloadMarker != 0 else {
            return nil
        }
        return ServerResult(code: code, expectedMode: expectedMode)
    }

    static func evaluate(
        expectedMode: ConnectionMode,
        clientMode: ConnectionMode,
        isLoopback: Bool
    ) -> ResultCode {
        guard expectedMode == clientMode else { return .wrongMode }
        let routeMatches = expectedMode == .usb ? isLoopback : !isLoopback
        return routeMatches ? .accepted : .wrongTransport
    }
}
