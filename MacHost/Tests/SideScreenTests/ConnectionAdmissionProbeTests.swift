import XCTest
@testable import SideScreen

final class ConnectionAdmissionProbeTests: XCTestCase {
    func testModeHelloMustMatchModeAndRouteBeforeTakeover() {
        let usbHello = ConnectionModeAdmission.encodeClientHello(mode: .usb)
        let wirelessHello = ConnectionModeAdmission.encodeClientHello(mode: .wireless)

        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: usbHello, expectedMode: .usb, isLoopback: true),
            .accept
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: wirelessHello, expectedMode: .usb, isLoopback: true),
            .reject(.wrongMode)
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: usbHello, expectedMode: .usb, isLoopback: false),
            .reject(.wrongTransport)
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: wirelessHello, expectedMode: .wireless, isLoopback: false),
            .accept
        )
    }

    func testProbeWaitsForCompleteMessages() {
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(
                data: Data([ConnectionModeAdmission.clientHelloType]),
                expectedMode: .usb,
                isLoopback: true
            ),
            .wait
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(
                data: Data([4, 0, 0, 0, 0, 0, 0, 0]),
                expectedMode: .usb,
                isLoopback: true
            ),
            .wait
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(
                data: Data([12, 0x8F, 0x80, 0x88, 0xB8]),
                expectedMode: .usb,
                isLoopback: true
            ),
            .accept
        )
    }

    func testLegacyProofAcceptsRecognizedMessagesOnly() {
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: Data([8]), expectedMode: .usb, isLoopback: true),
            .accept
        )

        var touch = Data(repeating: 0, count: 14)
        touch[0] = 2
        touch[1] = 1
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: touch, expectedMode: .usb, isLoopback: true),
            .accept
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: Data([2, 3]), expectedMode: .usb, isLoopback: true),
            .reject(nil)
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: Data([16, 0x89]), expectedMode: .usb, isLoopback: true),
            .reject(.invalidHello)
        )
        XCTAssertEqual(
            ConnectionAdmissionProbe.evaluate(data: Data([99]), expectedMode: .usb, isLoopback: true),
            .reject(nil)
        )
    }
}
