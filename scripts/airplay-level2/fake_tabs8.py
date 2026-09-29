#!/usr/bin/env python3
"""Level 2 rig: advertise a pyatv fake Apple TV as "TAB S8+ TEST".

Purpose: test which built-in Apple surfaces (iPhone Control Center, Apple TV
Remote, AirPlay picker, Home, Watch Remote / Now Playing / Home) discover a
non-Apple media endpoint and react to its MRP now-playing state — with zero
iOS/watchOS installs.

Upstream reference: pyatv scripts/fake_device.py (FakeAppleTV test rig).
Differences from stock script:
  - zeroconf instance name defaults to "TAB S8+ TEST" (all protocols)
  - fixed "--mode test-movie" state: PLAYING "TEST MOVIE", 10:00 into a
    45:00 runtime, volume 50% (matches the Level 2 experiment card)
  - no stdin wait (runs until SIGINT/SIGTERM; stock waits for ENTER)
  - Companion protocol omitted (its stock publisher hangs on this Mac;
    MRP + AirPlay is the experiment surface)
  - raw (HKP-less) transient ECDH pairing on /pair-setup + /pair-verify,
    per UxPlay raop_handler_pairsetup/pairverify: stock pyatv only speaks
    X-Apple-HKP 3/4 and answers real iPhones with 501, killing the route.
    HKP requests still delegate to the stock handlers.
  - optional RAOP service + _raop._tcp publisher (--no-raop to disable),
    giving iOS the auth-setup/RAOP-compat fallback route.

Requires: a pyatv checkout (default /tmp/pyatv) and its venv python, e.g.
  /tmp/pyatv-venv312/bin/python scripts/airplay-level2/fake_tabs8.py --mode test-movie
Verify from another terminal:
  /tmp/pyatv-venv312/bin/atvremote scan
  /tmp/pyatv-venv312/bin/atvremote -n "TAB S8+ TEST" playing
"""

import argparse
import asyncio
import hashlib
import logging
import os
import socket
import sys
from ipaddress import IPv4Address

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from zeroconf import Zeroconf

from pyatv.const import Protocol
from pyatv.core import mdns
from pyatv.support.http import HttpResponse

LOG = logging.getLogger("tabs8")

# KDF salts from UxPlay pairing.c (derive_key_internal + SALT_KEY/SALT_IV):
# key/iv = SHA512(salt || ecdh_secret)[:16], AES-128-CTR.
_PAIR_SALT_KEY = b"Pair-Verify-AES-Key"
_PAIR_SALT_IV = b"Pair-Verify-AES-IV"

DEFAULT_NAME = "TAB S8+ TEST"
AIRPLAY_IDENTIFIER = "4D797FD3-3538-427E-A47B-A32FC6CF3A6A"
SERVER_IDENTIFIER = "6D797FD3-3538-427E-A47B-A32FC6CF3A69"

# Single coherent AirPlay identity: mDNS TXT, /info plist, and the transient
# pairing device key must all agree, or real senders abort after /info.
AIRPLAY_DEVICEID = "00:01:02:03:04:05"
AIRPLAY_PI = "4EE5AF58-7E5D-465A-935E-82E4DB74385D"

# Two personas. "tv" is the AppleTV3,1 record that got us this far (iPhone
# completes transient M1-M4 against it, then quits: policy, not crypto).
# "speaker" mimics a real HomePod mini (Bedroom capture) — the device class
# transient no-PIN pairing was designed for.
PERSONAS = {
    "tv": {
        "model": "AppleTV3,1",
        "features": "0x5A7FFFF7,0xE",
        "flags": "0x44",
        "srcvers": "220.68",
    },
    "speaker": {
        "model": "AudioAccessory5,1",
        "features": "0x4A7FCA00,0x3C354BD0",
        "flags": "0x98484",
        "srcvers": "960.13.1",
        "protovers": "1.1",
        "osvers": "17.6",
        "fex": "AMp/StBLNTwQoS54",
        "btaddr": "00:01:02:03:04:06",
        "gid": "AABBCCDD-EEFF-0011-2233-445566778899",
        "gcgl": "1",
        "igl": "1",
        "acl": "0",
    },
}

TEST_TITLE = "TEST MOVIE"
TEST_POSITION_S = 600  # 10:00
TEST_TOTAL_S = 2700  # 45:00


def lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.168.1.1", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


async def publish_mrp(loop, zconf, name, address, port):
    props = {
        "ModelName": "Apple TV",
        "AllowPairing": "YES",
        "macAddress": "40:cb:c0:12:34:56",
        "BluetoothAddress": False,
        "Name": name,
        "UniqueIdentifier": SERVER_IDENTIFIER,
        "SystemBuildVersion": "17K499",
        "LocalAirPlayReceiverPairingIdentity": AIRPLAY_IDENTIFIER,
    }
    return await mdns.publish(
        loop,
        mdns.Service(
            "_mediaremotetv._tcp.local", name, IPv4Address(address), port, props
        ),
        zconf,
    )


async def publish_airplay(loop, zconf, name, address, port, pk_hex, persona):
    props = {
        "deviceid": AIRPLAY_DEVICEID,
        "model": persona["model"],
        "pi": AIRPLAY_PI,
        "flags": persona["flags"],
        "vv": "2",
        "features": persona["features"],
        "pk": pk_hex,
        "srcvers": persona["srcvers"],
    }
    for extra in ("protovers", "osvers", "fex", "btaddr", "gid", "gcgl",
                  "igl", "acl"):
        if extra in persona:
            props[extra] = persona[extra]
    return await mdns.publish(
        loop,
        mdns.Service(
            "_airplay._tcp.local", name, IPv4Address(address), port, props
        ),
        zconf,
    )


async def publish_raop(loop, zconf, name, address, port, pk_hex, persona):
    # Stock pyatv RAOP TXT shape; instance prefix is the AirPlay deviceid
    # without colons so senders correlate the two records.
    props = {
        "et": "0",
        "ss": "16",
        "am": "AudioAccessory5,1" if persona["model"].startswith("AudioAccessory")
        else "AppleTV6,2",
        "md": "0",
        "ch": "2",
        "sr": "44100",
        "cn": "1",
        "pk": pk_hex,
        "ft": persona["features"],
        "tp": "UDP",
        "vn": "65537",
        "vs": persona["srcvers"],
        "vv": "2",
    }
    return await mdns.publish(
        loop,
        mdns.Service(
            "_raop._tcp.local",
            "000102030405@{0}".format(name),
            IPv4Address(address),
            port,
            props,
        ),
        zconf,
    )


class RawPairingEndpoint:
    """UxPlay-style transient ECDH pairing for one AirPlay service.

    M1 (POST /pair-setup, 32 raw bytes, no X-Apple-HKP) -> M2 is our
    persistent Ed25519 device public key. M3 (POST /pair-verify step 1,
    68 bytes: 4-byte tag 1 || client X25519 ephemeral || client Ed25519
    pubkey) -> M4 is our X25519 ephemeral + Ed25519 signature over
    (server_eph || client_eph), signature AES-128-CTR encrypted. M5
    (pair-verify step 2, tag 0) carries the client's signature over
    (client_eph || server_eph), encrypted continuing the same CTR
    keystream (4-block offset); verified against the client's Ed key.
    """

    def __init__(self, seed: bytes = None):
        # Stable device identity across rig restarts: iOS caches pairings by
        # device/pk, and a rotating pk for the same name looks like an
        # impersonation attack (fail closed). Seed persisted next to script.
        if seed is None:
            key_file = os.path.join(
                os.path.dirname(os.path.realpath(__file__)), ".tabs8_device_key"
            )
            try:
                with open(key_file, "rb") as f:
                    seed = f.read(32)
                if len(seed) != 32:
                    raise ValueError("bad key length")
            except (OSError, ValueError):
                seed = os.urandom(32)
                with open(key_file, "wb") as f:
                    f.write(seed)
        self.device_priv = Ed25519PrivateKey.from_private_bytes(seed)
        self.device_pub = self.device_priv.public_key().public_bytes_raw()
        self.reset()
        LOG.warning("raw-pairing device Ed pubkey: %s", self.device_pub.hex())

    def reset(self):
        self.eph_priv = None
        self.eph_pub = None
        self.client_eph = None
        self.client_ed = None
        self.secret = None
        self.paired = False

    def _stream(self, skip_blocks=0):
        key = hashlib.sha512(_PAIR_SALT_KEY + self.secret).digest()[:16]
        iv = hashlib.sha512(_PAIR_SALT_IV + self.secret).digest()[:16]
        enc = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
        if skip_blocks:
            enc.update(b"\x00" * (16 * skip_blocks))
        return enc

    def step1(self, client_eph_raw: bytes, client_ed_raw: bytes) -> bytes:
        self.eph_priv = X25519PrivateKey.generate()
        self.eph_pub = self.eph_priv.public_key().public_bytes_raw()
        self.client_eph = client_eph_raw
        self.secret = self.eph_priv.exchange(
            X25519PublicKey.from_public_bytes(client_eph_raw)
        )
        self.client_ed = Ed25519PublicKey.from_public_bytes(client_ed_raw)
        sig = self.device_priv.sign(self.eph_pub + client_eph_raw)
        enc = self._stream()
        enc_sig = enc.update(sig) + enc.finalize()
        LOG.warning(
            "pair-verify step1 ok: client_eph=%s client_ed=%s ecdh_secret=%s",
            client_eph_raw.hex(),
            client_ed_raw.hex(),
            self.secret.hex(),
        )
        return self.eph_pub + enc_sig

    def step2(self, enc_sig: bytes) -> bool:
        if self.secret is None or self.client_ed is None:
            return False
        dec = self._stream(skip_blocks=4)
        raw_sig = dec.update(enc_sig) + dec.finalize()
        try:
            self.client_ed.verify(raw_sig, self.client_eph + self.eph_pub)
        except InvalidSignature:
            LOG.warning("pair-verify step2: BAD client signature")
            return False
        self.paired = True
        LOG.warning(
            "pair-verify step2 ok: PAIRED ecdh_secret=%s", self.secret.hex()
        )
        return True


def _body_bytes(request) -> bytes:
    body = request.body
    if isinstance(body, bytes):
        return body
    return body.encode("utf-8")


def _resp_summary(resp, full=False) -> tuple:
    body = resp.body or b""
    if isinstance(body, dict):
        body = repr(body).encode()
    if isinstance(body, str):
        body = body.encode()
    shown = body.hex() if full else body[:48].hex()
    return resp.code, len(body), shown


def _rtsp_ok(request, body: bytes):
    return HttpResponse(
        request.protocol,
        request.version,
        200,
        "OK",
        {
            "CSeq": request.headers.get("CSeq", "1"),
            "Content-Type": "application/octet-stream",
        },
        body,
    )


def tag_requests(service, tag):
    """Log every request with its owning service (kills port ambiguity)."""
    orig = service.handle_request

    def handle_request(request):
        LOG.warning(
            "%s %s %s cseq=%s", tag, request.method, request.path,
            request.headers.get("CSeq"),
        )
        return orig(request)

    service.handle_request = handle_request


def install_raw_pairing(airplay_service, name, persona) -> RawPairingEndpoint:
    """Route raw (non-HKP) /pair-setup + /pair-verify to UxPlay-style ECDH.

    Same (method, pattern) keys overwrite the stock handlers in the route
    table; HKP requests still delegate to the original bound methods.
    Also replaces GET /info (stock returns hardcoded junk contradicting the
    mDNS record) with a plist coherent with our advertised identity.
    All HKP pair-setup/pair-verify traffic is response-logged so the real
    iPhone handshake is fully observable (stock logs requests only).
    """
    endpoint = RawPairingEndpoint()
    orig_setup = airplay_service.handle_pair_setup
    orig_verify = airplay_service.handle_pair_verify

    def handle_info(request):
        import plistlib

        LOG.warning("coherent /info served to %s", request.headers.get("DACP-ID"))
        body = {
            "psi": "dc0eccfd-f834-47d5-95ce-d8f41e2544f6",
            "vv": 2,
            "playbackCapabilities": {
                "supportsInterstitials": False,
                "supportsFPSSecureStop": False,
                "supportsUIForAudioOnlyContent": False,
            },
            "canRecordScreenStream": False,
            "statusFlags": 4,
            "keepAliveSendStatsAsBody": True,
            "protocolVersion": "1.1",
            "volumeControlType": 3,
            "name": name,
            "senderAddress": "10.0.10.254:45285",
            "deviceID": AIRPLAY_DEVICEID,
            "macAddress": AIRPLAY_DEVICEID,
            "model": persona["model"],
            "features": persona["features"],
            "featuresEx": "AMp/StBrbbb",
            "pi": AIRPLAY_PI,
            "pk": endpoint.device_pub,
            "screenDemoMode": False,
            "initialVolume": -27.0,
            "sourceVersion": persona["srcvers"],
            "receiverHDRCapability": "4k60",
            "supportedFormats": {
                "audioStream": 21235712,
                "bufferStream": 1649282121728,
                "lowLatencyAudioStream": 4398080065536,
                "screenStream": 21235712,
            },
        }
        return HttpResponse(
            request.protocol,
            request.version,
            200,
            "OK",
            {
                "CSeq": request.headers.get("CSeq", "1"),
                "Content-Type": "text/x-apple-plist+xml",
            },
            plistlib.dumps(body),
        )

    def handle_pair_setup(request):
        hkp = request.headers.get("X-Apple-HKP")
        if hkp is not None:
            try:
                resp = orig_setup(request)
            except Exception:
                LOG.exception("HKP pair-setup blew up")
                raise
            # Real receivers answer pair-setup as octet-stream; stock claims
            # binary-plist for a TLV body. Match Apple on the wire.
            headers = dict(resp.headers)
            headers["Content-Type"] = "application/octet-stream"
            resp = resp._replace(headers=headers)
            code, length, shown = _resp_summary(resp, full=True)
            LOG.warning(
                "HKP pair-setup (hkp=%s cseq=%s) -> %s len=%d body=%s",
                hkp, request.headers.get("CSeq"), code, length, shown,
            )
            return resp
        body = _body_bytes(request)
        LOG.warning("RAW pair-setup M1: len=%d %s", len(body), body.hex())
        if len(body) != 32:
            return HttpResponse(
                request.protocol, request.version, 501, "Not implemented",
                {"CSeq": request.headers.get("CSeq", "1")}, b"",
            )
        endpoint.reset()
        LOG.warning("RAW pair-setup M2: device_pub=%s", endpoint.device_pub.hex())
        return _rtsp_ok(request, endpoint.device_pub)

    def handle_pair_verify(request):
        hkp = request.headers.get("X-Apple-HKP")
        if hkp is not None:
            try:
                resp = orig_verify(request)
            except Exception:
                LOG.exception("HKP pair-verify blew up")
                raise
            LOG.warning(
                "HKP pair-verify (hkp=%s cseq=%s) -> %s len=%d body=%s",
                hkp, request.headers.get("CSeq"), *_resp_summary(resp),
            )
            return resp
        body = _body_bytes(request)
        LOG.warning("RAW pair-verify: len=%d tag=%s", len(body), body[:4].hex())
        if len(body) != 68 or len(body[:4]) != 4:
            return HttpResponse(
                request.protocol, request.version, 400, "Bad Request",
                {"CSeq": request.headers.get("CSeq", "1")}, b"",
            )
        step = body[0]
        if step == 1:
            try:
                resp = endpoint.step1(body[4:36], body[36:68])
            except Exception:  # noqa: BLE001 - log and observe retries
                LOG.exception("pair-verify step1 failed")
                return HttpResponse(
                    request.protocol, request.version, 500,
                    "Internal Server Error",
                    {"CSeq": request.headers.get("CSeq", "1")}, b"",
                )
            return _rtsp_ok(request, resp)
        if step == 0:
            if endpoint.step2(body[4:68]):
                return _rtsp_ok(request, b"")
            return HttpResponse(
                request.protocol, request.version, 403, "Forbidden",
                {"CSeq": request.headers.get("CSeq", "1")}, b"",
            )
        return HttpResponse(
            request.protocol, request.version, 400, "Bad Request",
            {"CSeq": request.headers.get("CSeq", "1")}, b"",
        )

    airplay_service.add_route("POST", "^/pair-setup$", handle_pair_setup)
    airplay_service.add_route("POST", "^/pair-verify$", handle_pair_verify)
    airplay_service.add_route("GET", "^/info$", handle_info)
    return endpoint


async def demo_loop(usecase):
    while True:
        try:
            usecase.example_video()
            await asyncio.sleep(3)
            usecase.example_music()
            await asyncio.sleep(3)
            usecase.nothing_playing()
            await asyncio.sleep(3)
        except asyncio.CancelledError:
            break


async def appstart(args, loop):
    from tests.fake_device import FakeAppleTV  # noqa: E402
    import time as _time
    import tests.fake_device.mrp as _fake_mrp  # noqa: E402

    # Stock fake stamps playing updates with the Cocoa epoch, so a PLAYING
    # state reads as 100% elapsed to any client doing rate-based position
    # math (pyatv and real Apple clients alike). Stamp "now" instead so the
    # 10:00 position renders correctly. Drift after start is real-time
    # playback progression, which is the honest behavior for PLAYING.
    _fake_mrp._COCOA_BASE = _time.time() - 978307200

    zconf = Zeroconf()
    fake_atv = FakeAppleTV(loop, test_mode=False)
    tasks = []
    unpublishers = []

    _, mrp_usecase = fake_atv.add_service(Protocol.MRP)
    _, _airplay_state = fake_atv.add_service(Protocol.AirPlay)
    airplay_service = fake_atv.services[Protocol.AirPlay].service
    persona = PERSONAS[args.persona]
    raw_pairing = install_raw_pairing(airplay_service, args.name, persona)
    tag_requests(airplay_service, "AIRPLAY")
    if not args.no_raop:
        fake_atv.add_service(Protocol.RAOP)

    if args.mode == "test-movie":
        mrp_usecase.video_playing(
            paused=False,
            title=TEST_TITLE,
            total_time=TEST_TOTAL_S,
            position=TEST_POSITION_S,
        )
    else:
        tasks.append(asyncio.ensure_future(demo_loop(mrp_usecase)))

    await fake_atv.start()
    unpublishers.append(
        await publish_mrp(
            loop, zconf, args.name, args.local_ip, fake_atv.get_port(Protocol.MRP)
        )
    )
    unpublishers.append(
        await publish_airplay(
            loop, zconf, args.name, args.local_ip,
            fake_atv.get_port(Protocol.AirPlay),
            raw_pairing.device_pub.hex(),
            persona,
        )
    )
    if not args.no_raop:
        tag_requests(fake_atv.services[Protocol.RAOP].service, "RAOP")
        unpublishers.append(
            await publish_raop(
                loop, zconf, args.name, args.local_ip,
                fake_atv.get_port(Protocol.RAOP),
                raw_pairing.device_pub.hex(),
                persona,
            )
        )

    logging.warning(
        "TAB S8+ TEST rig up: name=%r ip=%s mode=%s persona=%s (Ctrl-C to stop)",
        args.name,
        args.local_ip,
        args.mode,
        args.persona,
    )
    try:
        await asyncio.Event().wait()
    finally:
        await fake_atv.stop()
        for task in tasks:
            task.cancel()
        for unpublish in unpublishers:
            await unpublish()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pyatv-dir", default="/tmp/pyatv")
    parser.add_argument("--local-ip", default=lan_ip())
    parser.add_argument("--name", default=DEFAULT_NAME)
    parser.add_argument("--mode", choices=["test-movie", "demo"], default="test-movie")
    parser.add_argument("--persona", choices=["tv", "speaker"], default="tv",
                        help="AirPlay device persona (mDNS + /info model/features)")
    parser.add_argument("--no-raop", action="store_true",
                        help="skip RAOP service + _raop._tcp publisher")
    parser.add_argument("-d", "--debug", action="store_true")
    args = parser.parse_args()

    sys.path.insert(0, args.pyatv_dir)
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.WARNING,
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s: %(message)s",
    )
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        return loop.run_until_complete(appstart(args, loop)) or 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
