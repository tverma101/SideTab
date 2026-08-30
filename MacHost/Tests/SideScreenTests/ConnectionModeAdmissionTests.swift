import XCTest
@testable import SideScreen

final class ConnectionModeAdmissionTests: XCTestCase {
    func testHelloRoundTripsBothModes() {
        for mode in ConnectionMode.allCases {
            let message = ConnectionModeAdmission.encodeClientHello(mode: mode)
            XCTAssertEqual(message.count, 2)
            XCTAssertEqual(message[0], ConnectionModeAdmission.clientHelloType)
            XCTAssertNotEqual(message[1] & 0x80, 0)
            XCTAssertEqual(
                ConnectionModeAdmission.decodeClientHello(type: message[0], payload: message[1]),
                mode
            )
        }
    }

    func testServerResultRoundTripsRejection() {
        let encoded = ConnectionModeAdmission.encodeServerResult(
            code: .wrongMode,
            expectedMode: .wireless
        )

        XCTAssertEqual(
            ConnectionModeAdmission.decodeServerResult(encoded),
            .init(code: .wrongMode, expectedMode: .wireless)
        )
    }

    func testAdmissionRequiresMatchingModeAndTransport() {
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .usb, clientMode: .usb, isLoopback: true),
            .accepted
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .wireless, clientMode: .wireless, isLoopback: false),
            .accepted
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .wireless, clientMode: .usb, isLoopback: true),
            .wrongMode
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .usb, clientMode: .usb, isLoopback: false),
            .wrongTransport
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .usb, clientMode: .wireless, isLoopback: false),
            .wrongMode
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .wireless, clientMode: .usb, isLoopback: false),
            .wrongMode
        )
        XCTAssertEqual(
            ConnectionModeAdmission.evaluate(expectedMode: .wireless, clientMode: .wireless, isLoopback: true),
            .wrongTransport
        )
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(ConnectionModeAdmission.decodeClientHello(type: 15, payload: 0x80))
        XCTAssertNil(ConnectionModeAdmission.decodeClientHello(type: 16, payload: 1))
        XCTAssertNil(ConnectionModeAdmission.decodeServerResult(Data([17, 0, 1])))
        XCTAssertNil(ConnectionModeAdmission.decodeServerResult(Data([17, 99, 0x80])))
    }
}
