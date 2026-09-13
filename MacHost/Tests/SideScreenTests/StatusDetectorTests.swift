import XCTest
@testable import SideScreen

final class StatusDetectorTests: XCTestCase {
    func testUsbSerialsIgnoreReadyWifiTransport() {
        let output = """
        List of devices attached
        R52X30G5TNB\tdevice usb:0-2 product:gts8pwifixx model:SM_X800 device:gts8pwifi transport_id:3
        192.168.1.130:45809\tdevice product:gts8pwifixx model:SM_X800 device:gts8pwifi transport_id:1
        unauthorized-device\tunauthorized usb:0-3
        offline-device\toffline usb:0-4
        """

        XCTAssertEqual(StatusDetector.usbSerials(from: output), ["R52X30G5TNB"])
    }

    func testUsbSerialsAcceptSpaceSeparatedDeviceListing() {
        let output = """
        List of devices attached
        USB_SERIAL device usb:1-4 product:test model:Tablet device:test transport_id:7
        WIFI_SERIAL device product:test model:Tablet device:test transport_id:8
        """

        XCTAssertEqual(StatusDetector.usbSerials(from: output), ["USB_SERIAL"])
    }

    func testReverseMappingParserMatchesWholePortFields() {
        let output = """
        host-17 tcp:54321 tcp:54321
        UsbFfs tcp:54323 tcp:54323
        """

        XCTAssertTrue(StatusDetector.reverseMappingConfigured(in: output, port: 54321))
        XCTAssertTrue(StatusDetector.reverseMappingConfigured(in: output, port: 54323))
        XCTAssertFalse(StatusDetector.reverseMappingConfigured(in: output, port: 5432))
        XCTAssertFalse(
            StatusDetector.reverseMappingConfigured(
                in: "host-17 tcp:543210 tcp:543210",
                port: 54321
            )
        )
    }
}
