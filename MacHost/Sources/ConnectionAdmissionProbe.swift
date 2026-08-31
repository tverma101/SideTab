import Foundation

/// Pure classification for a new video connection that arrived while another
/// client is active. The server uses this before promoting the candidate, so
/// malformed probes cannot evict a healthy stream.
enum ConnectionAdmissionProbe {
    enum Decision: Equatable {
        case wait
        case accept
        case reject(ConnectionModeAdmission.ResultCode?)
    }

    static func evaluate(
        data: Data,
        expectedMode: ConnectionMode,
        isLoopback: Bool
    ) -> Decision {
        let bytes = Array(data)
        guard let first = bytes.first else { return .wait }

        switch first {
        case ConnectionModeAdmission.clientHelloType:
            guard bytes.count >= 2 else { return .wait }
            guard let clientMode = ConnectionModeAdmission.decodeClientHello(
                type: first,
                payload: bytes[1]
            ) else {
                return .reject(.invalidHello)
            }
            let result = ConnectionModeAdmission.evaluate(
                expectedMode: expectedMode,
                clientMode: clientMode,
                isLoopback: isLoopback
            )
            return result == .accepted ? .accept : .reject(result)

        // Payload-free client capabilities that are sent at stream startup.
        case WireMessage.clientSupportsFrameMetadata,
             WireMessage.clientAvcOnly,
             WireMessage.clientSupportsFrameTrace,
             WireMessage.clientSupportsVideoClockSync:
            return .accept

        // Decoder limits: type + four high-bit-marked 7-bit payload bytes.
        case WireMessage.clientDecoderLimits, WireMessage.clientDecoderLimitsLegacy:
            guard bytes.count >= 5 else { return .wait }
            let payload = Array(bytes[1...4])
            guard payload.allSatisfy({ $0 & 0x80 != 0 }) else { return .reject(nil) }
            let width = (Int(payload[0] & 0x7F) << 7) | Int(payload[1] & 0x7F)
            let height = (Int(payload[2] & 0x7F) << 7) | Int(payload[3] & 0x7F)
            return width >= 256 && height >= 256 ? .accept : .reject(nil)

        // Complete ping/keyframe/touch messages are valid legacy proof.
        case WireMessage.ping:
            return bytes.count >= 9 ? .accept : .wait
        case WireMessage.keyframeRequest:
            return bytes.count >= 2 ? .accept : .wait
        case WireMessage.touchEvent:
            guard bytes.count >= 2 else { return .wait }
            let pointerCount = Int(bytes[1])
            guard pointerCount == 1 || pointerCount == 2 else { return .reject(nil) }
            let expectedSize = 2 + pointerCount * 8 + 4
            return bytes.count >= expectedSize ? .accept : .wait

        default:
            return .reject(nil)
        }
    }
}
