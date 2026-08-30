import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ANDROID_HANDSHAKE = (
    ROOT
    / "AndroidClient"
    / "app"
    / "src"
    / "main"
    / "java"
    / "com"
    / "sidescreen"
    / "app"
    / "ConnectionModeHandshake.kt"
)
MAC_HANDSHAKE = ROOT / "MacHost" / "Sources" / "ConnectionModeAdmission.swift"


class ConnectionModeContractTest(unittest.TestCase):
    def test_android_and_mac_use_the_same_reserved_wire_values(self):
        android = ANDROID_HANDSHAKE.read_text()
        mac = MAC_HANDSHAKE.read_text()

        self.assertEqual(
            re.search(r"CLIENT_HELLO_TYPE\s*=\s*(\d+)", android).group(1),
            re.search(r"clientHelloType:\s*UInt8\s*=\s*(\d+)", mac).group(1),
        )
        self.assertEqual(
            re.search(r"SERVER_RESULT_TYPE\s*=\s*(\d+)", android).group(1),
            re.search(r"serverResultType:\s*UInt8\s*=\s*(\d+)", mac).group(1),
        )
        self.assertIn("PAYLOAD_MARKER = 0x80", android)
        self.assertIn("payloadMarker: UInt8 = 0x80", mac)


if __name__ == "__main__":
    unittest.main()
