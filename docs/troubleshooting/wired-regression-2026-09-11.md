# Wired lag regression and rollback — 2026-09-11

## Symptom

The user reported that USB/ADB streaming had become laggy after the wireless
60-FPS efficiency work. Wireless remained the intended optimization target;
USB needed its previous low-latency behavior restored.

## Cause and recovery

The efficiency changes were shared across both transports in several places:

- the Mac listener's Network.framework service class changed to `.bestEffort`;
- ScreenCaptureKit received the dedicated callback queue and wireless idle-frame
  handling, including removal of the cached-frame fallback;
- Android applied the frame-rate hint and bounded frame pool to USB; and
- the USB partial wake-lock path had been removed.

The exact single contributor was not isolated. The safe recovery was to gate
those changes explicitly to wireless and restore the USB legacy paths. The
wireless reconnect and efficiency work remains in the working tree.

## Validation

- Mac Swift tests: 66 passed, 0 failures.
- Android unit tests: passed with 0 failures.
- Release host rebuilt, signed, installed at
  `/Users/tejas/Applications/SideScreen.app`, and launched.
- Debug APK rebuilt and installed over USB on the tablet; ADB reverse ports
  `54321` and `54322` were present.
- The installed pair established a live USB session. macOS reported
  `Active Client Connected`; Android sustained about 60 decoder inputs per
  second with about 12 ms average decoder latency and zero drops after the
  startup keyframe.
- The user then confirmed the wired path looked fixed.

## Evidence boundary and handoff

The rollback is implemented, source-tested, installed, live-tested, and
user-confirmed for USB. Wireless source work was preserved, but this turn did
not re-run wireless acceptance. The host and tablet were left in the validated
USB session. No source reset, pairing reset, staging, commit, push, PR,
workflow, or Actions change was performed.

If USB lag returns, collect paired Mac capture/encode/send counters and Android
decoder counters before changing transport code; do not undo the wireless-only
gates blindly.

## APK comparison — 2026-09-11

The nearest archived Android builds are from September 8 and September 9; no
September 10 APK snapshot is present. The exact APK installed on the tablet
today is `433ee2d0413f40efeb4252b6407f7f78099d10e414ae2a30de59d578f46d0e6a`,
installed at `2026-09-11 15:08:45`. The last older installed base recorded in
the provenance chain is `5d5298eccd5d09592eb83e495e8a5d5b03cd7db8659bf56ee353dc0d74b47ec6`,
from `backups/apk/20260909T195154Z/source-debug__app-debug.apk`; the cleanest
pre-September-9 wireless-change candidate is
`535913fd2ded8da591d4d25ac89ea98ee7d4bcfad3f64dd743a7e89ef6f865a6`, from
`backups/apk/20260908T213430Z/source-debug__app-debug.apk`.

Decompilation and binary entry comparison found no semantic change in
`VideoDecoder`, `CflRenderer`, or `SgsrRenderer` across these builds. USB's
`StreamClient` branch remains a direct socket to the host and uses the same
65,536-byte input stream buffer. The Android differences that can affect the
wired experience are in today's `MainActivity`: the older APK acquired the
30-minute partial wake lock at startup, while today's APK uses connection-time
display-awake handling and applies a `Surface.setFrameRate` hint even when the
session is wired. The remaining APK differences are wireless recovery,
multi-address, and wireless buffer-management changes.

This comparison identifies rollback candidates but does not prove which APK
was visually smooth; the manifests contain hashes and install provenance, not
user-confirmed visual acceptance. No APK was installed or reverted during the
comparison.

## Reverted to the known Sep 9 APK — 2026-09-11

The tablet was reverted over USB with `adb -s R52X30G5TNB install -r` to
`backups/apk/20260909T195154Z/source-debug__app-debug.apk`, whose SHA-256 is
`5d5298eccd5d09592eb83e495e8a5d5b03cd7db8659bf56ee353dc0d74b47ec6`. The
`-r` install preserved the package data directory; no uninstall, data clear, or
pairing reset was performed.

The current broken APK remains preserved at
`backups/apk/20260911T190836Z/source-debug__app-debug.apk` with SHA-256
`433ee2d0413f40efeb4252b6407f7f78099d10e414ae2a30de59d578f46d0e6a` and its
provenance manifest. After installation, Android reported version `0.11.2`,
code `1102`, and data directory `/data/user/0/com.sidescreen.app`. A
byte-level SHA-256 of the installed `/data/app/.../base.apk` matched the Sep 9
archive exactly. Visual smoothness after this revert is not user-confirmed yet.

No source reset, APK deletion, staging, commit, push, or GitHub/Actions change
was performed.

## Deeper Mac-side USB regression — 2026-09-11

### Symptom

After the Android APK rollback, USB still showed intermittent lag and spikes.
The Mac host was streaming while both the physical USB ADB transport and the
tablet's Wi-Fi ADB transport were online.

### Root cause

`StatusDetector` treated every ADB row in `device` state as USB, and the Mac
host used unscoped `adb reverse --list` and `adb reverse tcp:...` commands.
With both transports online, an unscoped ADB command returned `more than one
device/emulator`. The host interpreted the failed status probe as a missing
bridge and retried ADB reverse setup every few seconds during the live stream.
That created avoidable ADB process and repair churn on the Mac-side latency
path.

### Fix and regressions

- Physical USB selection now requires ADB's `usb:` transport metadata; Wi-Fi
  ADB rows are excluded.
- Reverse-list and reverse-setup commands are scoped to the selected USB
  serial, and failed reverse probes are not cached as valid state.
- A live USB stream is treated as proof that the reverse socket is usable, so
  the status refresh path does not keep spawning ADB repair processes during
  active playback.
- The server, capture pipeline, and encoder now carry an explicit session
  transport mode. USB cannot inherit wireless encoder or capture policy from a
  mutable preference while a session is running.
- Shell helpers and install/backup scripts use the same physical-USB
  selection rule.
- `StatusDetectorTests` covers mixed USB/Wi-Fi listings, space-separated ADB
  output, and whole-field reverse-port matching.

### Validation and evidence boundary

- Focused `StatusDetectorTests`: 3 passed, 0 failures.
- Full Mac Swift suite: 69 passed, 0 failures.
- ADB shell syntax checks and `git diff --check`: passed.
- With both transports online, the live listing selected only
  `R52X30G5TNB` as the physical USB serial.
- The rebuilt, signed host was installed at
  `/Users/tejas/Applications/SideScreen.app` and launched. The live USB
  session used ports `54321` and `54322`; the Mac pipeline reported roughly
  66–72 FPS, 9–15 ms average frame age, and zero drops, while Android reported
  zero decoder drops.
- No new `USB bridge missing` repair loop appeared after the rebuilt host
  started at 18:43:57, and the user confirmed the wired path was smooth again.

The Mac-side USB fix is implemented, source-tested, installed, live-tested,
and user-confirmed. Wireless acceptance was not re-run in this turn. The
saved USB refresh setting remains unchanged at 120 Hz. No staging, commit,
push, PR, workflow, or Actions change was performed.

If USB lag returns, collect paired Mac capture/encode/send counters and
Android decoder counters before changing transport code; first verify that
the ADB serial-scoped status path remains quiet during the active stream.
