<a id="readme-top"></a>

<div align="center">

<img src="resources/logo/sidescreen-icon.png" alt="SideTab" width="128"/>

<h1>SideTab</h1>

<p><em>Turn your Android tablet into a second display for macOS — USB-C or wireless over WiFi</em></p>

<p>
  <a href="https://github.com/tverma101/SideTab/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/tverma101/SideTab?style=for-the-badge&color=34C759" alt="License">
  </a>
  <a href="https://github.com/tverma101/SideTab/stargazers">
    <img src="https://img.shields.io/github/stars/tverma101/SideTab?style=for-the-badge&color=FF9500" alt="Stars">
  </a>
</p>

![Swift](https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![macOS](https://img.shields.io/badge/macOS_13+-000000?style=for-the-badge&logo=apple&logoColor=white)
![Android](https://img.shields.io/badge/Android_8+-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Universal Binary](https://img.shields.io/badge/Universal_Binary-Apple_Silicon_+_Intel-000000?style=for-the-badge&logo=apple&logoColor=white)

</div>

---

<div align="center">
  <img src="resources/screenshots/hero_screenshot.jpeg" alt="SideTab — Mac + Android tablet as second display" width="800"/>
</div>

---

## About

SideTab brings true second-display functionality to your Android tablet — over USB-C cable for the lowest latency, or wirelessly over WiFi after a one-time QR pair. Something macOS doesn't natively support either way.

While Apple's Sidecar only works with iPads, millions of Android tablets sit unused as potential workstations. SideTab bridges that gap with hardware-accelerated H.265 streaming, sub-16ms pipeline latency on USB, and full touch input — making your tablet feel like a real monitor, not a laggy mirror.

Built entirely open-source, SideTab is designed to be fast, lightweight, and seamlessly integrated.

The repository and product were renamed from Side Screen. Existing macOS and Android identifiers and the `sidescreen://` pairing scheme remain stable for compatibility.

For full details, features, and documentation, please visit **[sidescreen.dev](https://sidescreen.dev)**

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Features

### USB-C or Wireless

Two ways to connect, same picture quality. **USB-C** plugs in the cable for the lowest possible latency — the Mac app sets up adb-reverse forwarding for video on port `54321` and control on `54322`. **Wireless** uses a one-time QR pair; after that, the tablet keeps the encrypted pairing and **Reconnect** is the recovery action. The QR carries the Mac's preferred local address plus IPv4/IPv6 fallbacks, so a home WLAN that filters one address family can still use the other (5 GHz strongly recommended). Wireless sessions use a bounded 60 FPS profile: up to 40 Mbps average, a 60 Mbps one-second peak ceiling, and freshness-aware backpressure between capture, TCP, decoding, and presentation. The auth token is generated locally and stays on your Mac; reset it any time to revoke access. See [the wireless 60 FPS path](docs/wireless-60fps.md) for the implementation contract and validation boundary.

### Virtual Display

Create a true virtual display on your Mac. Drag windows to your tablet like a real monitor — not mirroring, but extending.

<div align="center">
  <img src="resources/screenshots/feature_virtual_display.png" alt="Virtual Display in macOS Display Preferences" width="600"/>
</div>

### Ultra-Low Latency

Hardware-accelerated H.265 encoding on Mac and decoding on Android. Async pipeline architecture delivers frames in under 30ms.

<div align="center">
  <img src="resources/screenshots/android_performance.png" alt="Low Latency Streaming with Stats Overlay" width="700"/>
</div>

### Touch Support

Use your tablet's touchscreen to interact with macOS. Touch prediction compensates for network latency, making taps and drags feel natural.

Samsung S Pen contact is handled as a direct drawing stroke rather than a touch scroll gesture. Current Mac/Android builds also forward pen pressure, hover movement, tilt/orientation metadata, and the S Pen secondary button. Pressure is delivered through macOS's tablet-style mouse event fields, so apps that read mouse/tablet pressure can vary brush width; this is not a kernel-level Wacom/Apple tablet driver.

### HiDPI (Retina) Support

Enable HiDPI mode to render at 2× resolution internally — text and icons are sharp at any logical resolution, just like a MacBook Retina display. Perfect for users with 2K/4K tablets who want a readable workspace without sacrificing sharpness.

### Gaming Mode

Enable Gaming Boost for the bounded ultra-low-latency encoder profile. The host pins this mode to its low-bitrate real-time profile; actual throughput depends on the selected display and device.

### Customizable

Configure resolution (up to 4K/8K), frame rate (30–120 FPS; 60 FPS is the current balanced default), bitrate and quality presets from the Mac app. The host applies a bounded encoder ladder rather than treating the UI bitrate as an unrestricted wire rate.

<div align="center">
  <img src="resources/screenshots/mac_settings_1.png" alt="macOS Settings — Display & FPS" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/mac_settings_2.png" alt="macOS Settings — Streaming & Status" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/android_settings.png" alt="Android — Connection Screen" height="500"/>
</div>

### Headless / portable Mac

Run a Mac with no display of its own — a Mac Studio or Mini on the go, or a laptop in clamshell — using the tablet as its only screen. Enable Launch at Login and Auto-start streaming, and the Mac boots straight into serving the tablet, with nothing to press on the Mac.

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Requirements

| | macOS Host | Android Client |
|---|---|---|
| **OS** | macOS 13 (Ventura)+ | Android 8.0 (API 26)+ |
| **Hardware** | Apple Silicon or Intel | H.265 hardware decoder |
| **USB mode** | USB-C port + `adb` (Android SDK platform-tools preferred; Homebrew is a fallback) | USB-C cable + USB Debugging enabled |
| **Wireless mode** | Same WiFi network as the tablet (5 GHz recommended) | Camera for first pair/re-pair + Google Play Services (for ML Kit barcode) |

---

## Installation

This fork does not currently publish installers on GitHub Releases. Build the
current source version shown in `VERSION` using the instructions below. The
macOS build script writes each DMG and its source/checksum manifest under
`dist/SideScreen-<version>/<build-id>/` so builds from different versions stay
identifiable. After a successful build, `dist/current/` points to the newest
build. Use that DMG when installing; the root `SideScreen.app` is build
staging, while the installer manages the single user-facing copy at
`~/Applications/SideScreen.app`.

For Android, the APK built from the current checkout is always
`AndroidClient/app/build/outputs/apk/debug/app-debug.apk`. Run
`./scripts/install_android.sh` to rebuild and install that exact output. Files
under `backups/apk/` are recovery snapshots and should not be selected as
installers.

> **⚠️ macOS Gatekeeper**
> If macOS says the app is "damaged", open Terminal and run:
> ```bash
> sudo xattr -cr /Applications/SideScreen.app
> ```
> Then open the app again. This is needed because the app is not notarized with an Apple Developer certificate.

> **⚠️ ADB Required**
> The Mac app needs `adb` to communicate with your Android device. If the app doesn't show "Running" after launch, you likely need to install ADB:
>
> SideTab uses the Android SDK's `platform-tools/adb` when it is installed, then falls back to Homebrew. This keeps the Mac app, APK installer, and `adb reverse` tunnel on one toolchain. Set `SIDESCREEN_ADB=/absolute/path/to/adb` when an alternate SDK must be used.
>
> 1. Install Homebrew (if you don't have it):
>    ```bash
>    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
>    ```
> 2. Install ADB:
>    ```bash
>    brew install --cask android-platform-tools
>    ```

<details>
<summary><strong>Build from source (for developers)</strong></summary>

```bash
git clone https://github.com/tverma101/SideTab.git
cd SideTab

# macOS (universal signed app bundle; also removes stale local app snapshots)
./scripts/build_mac.sh

# Optional: install exactly one user-facing copy under ~/Applications
./scripts/install_mac.sh --launch

# Android debug APK
./scripts/build_android.sh

# Put the current Mac DMG and Android APK in one versioned folder
./scripts/package_current.sh

# Rebuild the current source and install on the connected tablet
./scripts/install_android.sh
# Explicitly install an existing APK without rebuilding
./scripts/install_android.sh --skip-build

# Preserve every local APK and the currently installed APK before installing
./scripts/backup_android_apks.sh
```

The Mac DMG and its `BUILD-MANIFEST.txt` are written to
`dist/SideScreen-<VERSION>/<build-id>/`; the newest is also reachable at
`dist/current/SideScreen-<VERSION>-mac-universal.dmg`. Android APKs are
generated under `AndroidClient/app/build/outputs/apk/`. Use the debug
`app-debug.apk` there for this local checkout; the installer script rebuilds
it before installing. The raw build output directories are excluded from Git.

After both platform builds, `./scripts/package_current.sh` verifies the Mac
signature and architectures, checks the APK metadata, then copies the pair
into `artifacts/SideScreen-<VERSION>/` with source provenance and SHA-256
checksums in `MANIFEST.txt`. That folder contains the two installers and
manifest; it does not include a second loose `.app` bundle.

The backup helper creates a non-overwriting snapshot under
`backups/apk/<UTC-timestamp>/`. These are local recovery files and are not
tracked in Git. Each snapshot includes the available debug and
release APK outputs, `installed-base.apk` when a connected ADB device has Side
Screen installed, and `MANIFEST.txt` with version, signing-certificate, source
revision, device, and SHA-256 details. Set `SIDESCREEN_ADB_SERIAL` when more
than one Android device is connected.

If the Mac status says **Authorize tablet**, ADB can see the USB device but
the tablet has not trusted this Mac yet. Unlock the tablet and accept the USB
debugging prompt. The USB reverse tunnel and Android connection cannot start
until ADB reports the tablet as `device` rather than `unauthorized`.

The macOS installer replaces the exact `~/Applications/SideScreen.app` target
without creating `SideScreen.app.previous.*` copies. Successful macOS builds,
runs, and installs also move any verified stale snapshots left by older
installers to the macOS Trash. The Trash is not emptied automatically, and
unrelated applications are never searched or changed.
</details>

---

## Usage

### USB mode (default — lowest latency)

1. Connect tablet to Mac via **USB-C**
2. Launch **SideTab** on Mac (runs in menu bar — port forwarding is set up automatically)
3. Open **SideTab** on tablet → keep on the **USB** tab → tap **Connect**
4. Done — drag windows to your new display

The Android display stays awake while a stream is active and the app is
visible. Android can sleep the display when the app is backgrounded; an
unattended background session disconnects after five minutes by default.
Leave the USB port field blank to use the defaults. A custom video port must
be from `1` to `65534`, since Android uses the next port for control traffic.

The Mac pauses screen capture after 15 seconds with no connected tablet and
resumes it on Connect. When ScreenCaptureKit confirms the desktop has not
changed, the Mac skips re-encoding that frame; Android's video and control
pings keep quiet sessions alive without sending duplicate frames.

A session that receives nothing from the tablet for five minutes — a Wi-Fi
association that dropped without a clean close, a tablet that went to sleep —
is timed out by the Mac, which stops streaming and releases the virtual
display instead of holding a stale "Connected" state. The deadline is measured
from bytes the tablet sends, never from frames the Mac pushes, so a socket that
is accepted-but-never-read cannot keep a session alive on its own.

### Wireless mode (no cable)

1. Launch **SideTab** on Mac → toggle to the **Wireless** tab → a QR code appears
2. Open **SideTab** on tablet → switch to the **Wireless** tab → tap **Scan QR Code** → grant camera permission → aim at the QR on the Mac
3. The tablet remembers the Mac. On subsequent launches, open the Wireless tab and tap **Reconnect** — no rescan is needed unless the token or Mac address changed.

Wireless mode requires both devices to be on the same WiFi network. **5 GHz is strongly recommended** — 2.4 GHz can introduce noticeable jitter on dynamic content. The pairing token authenticates the wireless stream but does not currently provide end-to-end encryption, so use a trusted network. If you need to revoke access, click **Reset Token (forget all)** on the Mac and re-pair each tablet.

Wireless defaults to the native Android `SurfaceView` presentation path. VSR/CfL enhancement remains opt-in, so disabling it keeps the tablet on the lowest-overhead hardware decode path.

USB mode remains the lowest-latency option for drawing or fast-paced gaming. Its normal SDR capture uses video-range `420v` signaling to match the Android hardware decoder and prevent washed or contrast-shifted colors. Wireless adds 10–50 ms depending on WiFi quality. The old full-range `420f` path is retained only as an explicit diagnostic control (`defaults write com.sidescreen.app SideScreen_exp_pixelFormat -string 8bit`).

The Mac menu-bar menu includes a compact **Tablet Brightness** slider. It controls the Android panel through the low-latency control channel, remembers the selected level while disconnected, and reapplies it when the tablet reconnects.

### Headless mode (no Mac interaction)

In Settings → Startup, turn on **Launch at Login** and **Auto-start streaming on launch**, then pick the **Startup mode** (USB or Wireless). On your next login the server starts automatically — just open SideTab on the tablet and tap Connect (USB) or Reconnect (Wireless).

First-time setup still needs a screen once to grant Screen Recording permission; after that the Mac runs fully headless. For wireless headless use, give the Mac a static IP or DHCP reservation, and consider enabling macOS Screen Sharing as a fallback way in.

---

## Configuration

| Setting | Options | Default |
|---------|---------|---------|
| Resolution | 720p to 8K, 30+ presets + custom | 1920x1200 |
| Frame Rate | USB: 30, 60, 90, 120 FPS; Wireless: bounded at 60 FPS | 60 |
| Bitrate | Host-bounded quality ladder | Host preset |
| Quality | Ultra Low, Low, Medium, High | Ultra Low |
| HiDPI (Retina) | On/Off | Off |
| Gaming Boost | On/Off (bounded low-latency profile) | Off |
| Touch Input | On/Off (gates touch and S Pen together) | On |

### Input source (tablet)

Set on the tablet under **Settings → Input Source**, and applies live without
reconnecting:

| Mode | Finger | S Pen |
|------|--------|-------|
| Both | Controls Mac | Draws on Mac |
| Touch | Controls Mac | Ignored |
| Pen | Ignored | Draws on Mac |
| Off | Ignored | Ignored |

The Mac's own **Touch Control** setting still applies and overrides this, so if
nothing responds, check the Mac first. Changing the mode mid-gesture ends the
current drag rather than leaving a stuck mouse button on the Mac.

---

## Troubleshooting

<details>
<summary><strong>"SideTab is damaged" on macOS</strong></summary>

This happens because the app is not notarized by Apple. Run this command to fix it:
```bash
sudo xattr -cr /Applications/SideScreen.app
```
Then open the app again.
</details>

<details>
<summary><strong>"Connection refused" on Android</strong></summary>

The Mac app sets up `adb reverse` automatically when streaming starts. If it still fails, run `./scripts/setup-usb.sh` from the repo; it prints the selected ADB binary and the full device state (`device`, `unauthorized`, or `offline`). Make sure the tablet is unlocked, using a data-capable USB mode, and has accepted the USB debugging prompt. A charge-only cable will not enumerate as an ADB device.
</details>

<details>
<summary><strong>Android keeps trying to reconnect</strong></summary>

Current Android builds only connect after you tap **Connect** or **Reconnect**. They do not resume a saved session or retry a dropped connection by themselves. Reinstall the current APK if an older build is still running, then launch the app again.

The connection checklist checks tablet-local prerequisites while idle; it does not open a Mac socket until you explicitly connect.
</details>

<details>
<summary><strong>High latency or stuttering</strong></summary>

- Lower resolution or frame rate
- Ensure H.265 hardware codec support on your device
- For USB mode, use a high-quality USB-C cable (not charge-only)
- For wireless mode, ensure both devices are on **5 GHz WiFi**, not 2.4 GHz; reduce refresh rate to 60 Hz if jitter persists
</details>

<details>
<summary><strong>Wireless: "Couldn't reach Mac" / connection times out</strong></summary>

- Both devices must be on the same WiFi network (and same subnet — some mesh routers isolate "guest" devices)
- Click **Start** on the Mac before scanning the QR — the listener only binds when the server is running
- If Android already has a pairing, tap **Reconnect** first. The repair screen keeps the saved pairing and makes **Pair again (scan QR)** the secondary action; scan a fresh QR only if the Mac pairing token was reset or discovery cannot recover the Mac
- The QR includes compatible local IPv4/IPv6 addresses, and Bonjour recovery also returns all usable addresses. This preserves normal WiFi/Internet on the tablet; SideTab does not create a private hotspot
- If both devices show addresses in the same subnet but Reconnect still times out, test device-to-device TCP reachability; campus or guest WiFi can isolate clients and block both TCP and Bonjour even when the addresses look local. Use a non-isolated SSID or disable client isolation on the access point.
- macOS may prompt for **Local Network** permission on first wireless toggle — grant it; without it, LAN inbound is silently dropped
</details>

<details>
<summary><strong>Wireless: "Re-pair required" after restart / reinstall</strong></summary>

The Mac's auth token resets when you click **Reset Token (forget all)** or reinstall the app. Tap **Scan QR Code** on the Android client and scan the new QR shown on the Mac.
</details>

<details>
<summary><strong>Virtual display not appearing</strong></summary>

Grant Screen Recording permission: **System Preferences → Privacy & Security → Screen Recording → Enable SideTab**
</details>

---

## Contributing

Contributions are welcome!

- ⭐ **Star** this repo to help others discover it
- 🐛 **Report bugs** via [Issues](https://github.com/tverma101/SideTab/issues)
- 💡 **Suggest features** via [Issues](https://github.com/tverma101/SideTab/issues)
- 🔧 **Submit PRs** — see [CONTRIBUTING.md](CONTRIBUTING.md)

---

## Support

If SideTab is useful to you, consider supporting development:

<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/tranvuongqk)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=github-sponsors&logoColor=white)](https://github.com/sponsors/tranvuongquocdat)
[![VietQR](https://img.shields.io/badge/Vietnam-VietQR-DA251D?style=for-the-badge&logoColor=white)](https://sidescreen.dev/donate.html)

</div>

🇻🇳 Vietnamese users — scan VietQR for a local bank transfer (no international fees) at [sidescreen.dev/donate](https://sidescreen.dev/donate.html).

---

## Privacy

SideTab does not request or collect device location. See [PRIVACY.md](PRIVACY.md)
for the exact permissions and data-flow boundary.

---

## License

[MIT License](LICENSE) — free for personal and commercial use.

---

<div align="center">

Made with ❤️ by **Tran Vuong Quoc Dat**

[Report Bug](https://github.com/tverma101/SideTab/issues) · [Request Feature](https://github.com/tverma101/SideTab/issues) · [Discussions](https://github.com/tverma101/SideTab/discussions)

</div>
