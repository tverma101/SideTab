<div align="center">

<img src="resources/logo/sidescreen-icon.png" alt="Side Screen icon" width="112" />

# Side Screen

**Use an Android tablet as a second display for macOS over USB or Wi‑Fi.**

[![License](https://img.shields.io/github/license/tverma101/SideScreen?style=flat-square)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple)](MacHost/Package.swift)
[![Android 8+](https://img.shields.io/badge/Android-8%2B-3DDC84?style=flat-square&logo=android&logoColor=white)](AndroidClient/app/build.gradle.kts)
[![GitHub stars](https://img.shields.io/github/stars/tverma101/SideScreen?style=flat-square)](https://github.com/tverma101/SideScreen/stargazers)

</div>

<p align="center">
  <img src="resources/screenshots/hero_screenshot.jpeg" alt="Side Screen running on macOS and Android" width="760" />
</p>

## Project status

Side Screen is under active development. The repository version is **0.11.2**; `main` also contains unreleased fixes and performance work newer than that version.

This fork currently does **not** publish binaries through GitHub Releases. Build from source when testing this repository so the Mac host and Android client come from the same code revision.

| Area | Current state |
| --- | --- |
| USB display | Primary validation path; video, touch, high refresh rates, and S Pen support are implemented |
| Wireless display | Functional, but transport/security and reconnect work remain |
| Display profile | Current fork uses a fixed 1400×876 logical HiDPI profile (2800×1752 physical) |
| Refresh rate | 30 / 60 / 90 / 120 Hz are exposed; 60 Hz is the normal default |
| macOS | macOS 13 Ventura or newer |
| Android | API 26 / Android 8.0 or newer |

See [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) for the current production blockers, experiments, and issue map.

> [!IMPORTANT]
> Wireless video traffic is not yet end-to-end encrypted. Use wireless mode only on a trusted network until the Protocol V2 / TLS work is complete. USB remains local through the ADB reverse-forwarding path.

## What it does

- Creates a virtual display on macOS and captures it with ScreenCaptureKit.
- Encodes the display with VideoToolbox and streams it to the Android client.
- Uses Android MediaCodec for hardware-assisted decode where supported.
- Supports USB through ADB reverse port forwarding and wireless connections on the local network.
- Forwards touch input from the tablet to macOS.
- Supports Samsung S Pen contact, pressure/tilt metadata, hover, and the secondary button on the negotiated stylus path.
- Supports HEVC with H.264 fallback for clients that cannot decode HEVC.
- Supports display rotation, mirroring, launch-at-login, and automatic host startup.

Performance numbers are intentionally not advertised as fixed guarantees. End-to-end latency and sustained 120 Hz behavior depend on the Mac, Android decoder, panel mode, connection, content, and current branch. The repository tracks measurement work explicitly rather than presenting partial pipeline timestamps as glass-to-glass latency.

## Requirements

### macOS host

- macOS 13 Ventura or newer
- Swift 5.9+ / a compatible Xcode toolchain
- Screen Recording permission
- Accessibility permission for tablet-to-Mac input
- ADB for USB mode

### Android client

- Android 8.0 / API 26 or newer
- USB debugging enabled for USB mode
- Camera permission only when scanning a wireless pairing QR code

## Build from source

Clone this repository:

```bash
git clone https://github.com/tverma101/SideScreen.git
cd SideScreen
```

### macOS

The repository build script creates a universal app bundle and DMG:

```bash
./scripts/build_mac.sh
open SideScreen.app
```

On first launch, grant the requested **Screen Recording** and **Accessibility** permissions in System Settings.

### Android

Build the debug APK:

```bash
./scripts/build_android.sh
```

The APK is written to:

```text
AndroidClient/app/build/outputs/apk/debug/app-debug.apk
```

With an Android device connected through ADB, the repository installer can install the current debug build:

```bash
./scripts/install_android.sh
```

Release APKs intentionally require explicit release-signing credentials and do not silently fall back to the debug key.

## Connect

### USB

1. Enable **Developer options → USB debugging** on the Android tablet.
2. Connect the tablet to the Mac with a data-capable USB cable.
3. Accept the Android USB-debugging authorization prompt if shown.
4. Start Side Screen on the Mac.
5. Open Side Screen on Android and connect.

The helper scripts use ADB reverse forwarding for the video and control ports.

### Wireless

1. Put the Mac and tablet on the same trusted local network.
2. Select **Wireless** on the Mac host.
3. Pair the Android client using the QR flow.
4. Connect from the tablet.

Wireless pairing credentials are protected at rest on Android, but the current video transport is still cleartext. Network encryption and stronger session binding are tracked as production work.

## Current configuration

The current `main` branch is intentionally tuned around a fixed tablet profile rather than the older upstream resolution picker:

- Logical resolution: **1400 × 876**
- HiDPI physical size: **2800 × 1752**
- Refresh options: **30 / 60 / 90 / 120 Hz**
- Default refresh: **60 Hz**
- Default video port: **54321**
- Control port: **54322**

High refresh rates are available for testing, but they are not assumed to be sustainable on every Mac/tablet combination.

## Development

Useful entry points:

```text
MacHost/Sources/                  macOS host
MacHost/Tests/                    Swift tests
AndroidClient/app/src/main/       Android client
AndroidClient/app/src/test/       JVM tests
scripts/                          build, install, benchmark, and maintenance tools
docs/                             architecture, validation, and experiment notes
```

Before opening a pull request, read [`CONTRIBUTING.md`](CONTRIBUTING.md). Changes to capture, encode, transport, decode, rendering, lifecycle, or input paths should include deterministic tests where possible and real-device evidence when the behavior cannot be proven on hosted CI.

## Known work

The issue tracker contains both product blockers and research/measurement tasks. The highest-value unfinished areas are:

- authenticated, encrypted Protocol V2 for wireless sessions;
- macOS lock/sleep and Android wake/reconnect lifecycle handling;
- Android runtime/session ownership cleanup;
- trustworthy end-to-end latency and smoothness instrumentation;
- WindowServer / 120 Hz cost attribution;
- real-device validation of adaptive high-refresh behavior.

A curated map with issue numbers and merge gates lives in [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md).

## Contributing

Bug reports should include the exact Mac model/macOS version, Android device/Android version, connection mode, app revision, reproduction steps, and relevant logs. For performance reports, include the configured resolution/refresh rate and whether the symptom is visible stutter, latency, decoder recovery, bandwidth, CPU/GPU load, or connection failure.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full workflow.

## Privacy and security

See [`PRIVACY.md`](PRIVACY.md) for data-handling boundaries. Do not post pairing secrets, signing credentials, private network credentials, or other sensitive material in public issues or logs.

## License and attribution

Side Screen is available under the [MIT License](LICENSE).

This repository is a maintained fork of the Side Screen project originally created by **Trần Vương Quốc Đạt**. Historical changelog entries and contributor credits are preserved so authorship remains clear. Fork-specific maintenance and development are tracked in this repository.
