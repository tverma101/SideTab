<a id="readme-top"></a>

<div align="center">

<img src="resources/logo/sidescreen-icon.png" alt="Side Screen" width="128"/>

<h1>Side Screen</h1>

<p><em>Turn your Android tablet into a second display for macOS — USB-C or wireless over WiFi</em></p>

<p>
  <img src="https://img.shields.io/github/v/release/tranvuongquocdat/SideScreen?style=for-the-badge&label=version&color=blue" alt="Version">
  <a href="https://github.com/tranvuongquocdat/SideScreen/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/tranvuongquocdat/SideScreen?style=for-the-badge&color=34C759" alt="License">
  </a>
  <a href="https://github.com/tranvuongquocdat/SideScreen/stargazers">
    <img src="https://img.shields.io/github/stars/tranvuongquocdat/SideScreen?style=for-the-badge&color=FF9500" alt="Stars">
  </a>
  <a href="https://github.com/tranvuongquocdat/SideScreen/releases">
    <img src="https://img.shields.io/github/downloads/tranvuongquocdat/SideScreen/total?style=for-the-badge&color=8E44AD&label=downloads" alt="Downloads">
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
  <img src="resources/screenshots/hero_screenshot.jpeg" alt="Side Screen — Mac + Android tablet as second display" width="800"/>
</div>

---

## About

Side Screen brings true second-display functionality to your Android tablet — over USB-C cable for the lowest latency, or wirelessly over WiFi after a one-time QR pair. Something macOS doesn't natively support either way.

While Apple's Sidecar only works with iPads, millions of Android tablets sit unused as potential workstations. Side Screen bridges that gap with hardware-accelerated H.265 streaming, sub-16ms pipeline latency on USB, and full touch input — making your tablet feel like a real monitor, not a laggy mirror.

Built entirely open-source, Side Screen is designed to be fast, lightweight, and seamlessly integrated.

For full details, features, and documentation, please visit **[sidescreen.dev](https://sidescreen.dev)**

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Features

### USB-C or Wireless

Two ways to connect, same picture quality. **USB-C** plugs in the cable for the lowest possible latency — adb-reverse port forwarding is set up automatically. **Wireless** lets you scan a QR code from the Mac once, then tap **Reconnect** when you choose to start a session over WiFi (5 GHz strongly recommended). Wireless uses a bounded efficiency profile: capture and encode are fixed at 60 FPS with a 40 Mbps average / approximately 60 Mbps one-second peak. The auth token is generated locally and stays on your Mac; reset it any time to revoke access.

The experimental Android sRGB/BT.709 color bridge is presentation-capped at 60 FPS and asks the tablet decoder for a 60 FPS operating rate. It drains to the newest decoded frame rather than queueing stale frames, so the cap protects smoothness and power without changing the normal USB 10-bit path. The macOS virtual-display mode, ScreenCaptureKit capture ceiling, and encoder now share the same effective rate: Main10 is held at 60 FPS, while 8-bit/Main remains eligible for 120 FPS.

### Virtual Display

Create a true virtual display on your Mac. Drag windows to your tablet like a real monitor — not mirroring, but extending.

<div align="center">
  <img src="resources/screenshots/feature_virtual_display.png" alt="Virtual Display in macOS Display Preferences" width="600"/>
</div>

### Tablet Brightness

Use the native **Tablet Brightness** slider in SideScreen Settings or the menu-bar menu to control the tablet's actual panel backlight. The value is remembered while disconnected and reapplied automatically when the tablet reconnects; F1/F2 brightness keys remain available as a keyboard shortcut, including keyboards configured to send ordinary F1/F2 events. SideScreen prefers its low-latency control channel and falls back to the live video connection if that optional channel drops. This control belongs to SideScreen because the macOS Displays pane cannot drive the Android tablet's backlight through the virtual display.

### Android session lifecycle

The Android client keeps a normal app shell while idle: system bars, the user's brightness mode, screen-power policy, touch forwarding, and decoder resources remain untouched. Fullscreen presentation, screen-awake ownership, transactional brightness, and touch forwarding begin only after the current connection has negotiated a display, started its decoder, and produced a frame through the render path. Disconnect and failure release those resources and return to the normal shell. If the optional control channel drops while video continues, the session stays connected and reports controls as degraded instead of hiding a healthy picture.

The USB checklist is intentionally advisory. `UsbManager.deviceList` describes Android acting as a USB host, while SideScreen's ADB-reverse route has the Mac as host and the tablet as the USB device. Tap **Connect** to verify the actual route; the checklist does not probe the Mac listener in the background.

Decoder selection and frame timing are recorded in the Android diagnostic log: codec hardware/vendor/software classification, supported size/rate, low-latency feature, profiles, configure fallback, codec metrics, output release, and `OnFrameRenderedListener` timing. The Mac log separately reports WindowServer display-time → ScreenCaptureKit callback delay and the later encode/send stages. See [docs/android-session-lifecycle.md](docs/android-session-lifecycle.md) for the state contract and evidence checklist.

### Ultra-Low Latency

Hardware-accelerated H.265 encoding on Mac and decoding on Android. Async pipeline architecture delivers frames in under 30ms.

<div align="center">
  <img src="resources/screenshots/android_performance.png" alt="Low Latency Streaming with Stats Overlay" width="700"/>
</div>

### Touch Support

Use your tablet's touchscreen to interact with macOS. Touch prediction compensates for network latency, making taps and drags feel natural.

### HiDPI (Retina) Support

Enable HiDPI mode to render at 2× resolution internally — text and icons are sharp at any logical resolution, just like a MacBook Retina display. Perfect for users with 2K/4K tablets who want a readable workspace without sacrificing sharpness.

### Gaming Mode

Enable Gaming Boost for optimized settings: 1 Gbps bitrate, ultra-low latency encoding, 120 FPS.

### Customizable

Configure resolution (up to 4K/8K), frame rate (30–120 FPS), bitrate (20–5000 Mbps), and quality presets from the Mac app.

<div align="center">
  <img src="resources/screenshots/mac_settings_1.png" alt="macOS Settings — Display & FPS" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/mac_settings_2.png" alt="macOS Settings — Streaming & Status" height="500"/>
  &nbsp;&nbsp;
  <img src="resources/screenshots/android_settings.png" alt="Android — Connection Screen" height="500"/>
</div>

### Headless / portable Mac (new in 0.11.0)

Run a Mac with no display of its own — a Mac Studio or Mini on the go, or a laptop in clamshell — using the tablet as its only screen. Enable Launch at Login and Auto-start streaming, and the Mac boots straight into serving the tablet, with nothing to press on the Mac.

<p align="right"><a href="#readme-top">↑ Back to top</a></p>

---

## Requirements

| | macOS Host | Android Client |
|---|---|---|
| **OS** | macOS 13 (Ventura)+ | Android 8.0 (API 26)+ |
| **Hardware** | Apple Silicon or Intel | H.265 hardware decoder |
| **USB mode** | USB-C port + `adb` (`brew install android-platform-tools`) | USB-C cable + USB Debugging enabled |
| **Wireless mode** | Same WiFi network as the tablet (5 GHz recommended) | Camera (for QR scan) + Google Play Services (for ML Kit barcode) |

---

## Installation

Download the latest release from [**GitHub Releases**](https://github.com/tranvuongquocdat/SideScreen/releases):

- **macOS**: Download `.dmg`, open it, drag Side Screen to Applications
- **Android**: Download `.apk`, install on your tablet (enable "Unknown sources" if needed). Port forwarding is handled automatically by the Mac app.

> **⚠️ macOS Gatekeeper**
> If macOS says the app is "damaged", open Terminal and run:
> ```bash
> sudo xattr -cr /Applications/SideScreen.app
> ```
> Then open the app again. This is needed because the app is not notarized with an Apple Developer certificate.

> **⚠️ Screen Recording identity**
> macOS grants Screen Recording to the app's designated signing requirement, not
> just the visible name. Local development builds must use the same Apple
> Development identity, Team ID, and bundle ID on every rebuild. Check that
> Xcode has a Personal Team certificate before building:
> ```bash
> security find-identity -v -p codesigning
> ```
> If no `Apple Development: ...` identity appears, open Xcode → Settings →
> Apple Accounts and create/select the Personal Team certificate. The build
> scripts intentionally fail instead of silently producing an ad-hoc build.
>
> For a local build, install and launch the one canonical bundle:
> ```bash
> ./scripts/build_mac.sh
> ./scripts/install_mac.sh --launch
> ```
> The installer uses `~/Applications/SideScreen.app` and preserves the
> previous bundle with a `.previous.<timestamp>` suffix. Do not launch an
> `exp_bin/SideScreenExp.app`, a build artifact in another checkout, or another
> copy with the same display name. The CDHash may still change on each build;
> the stable certificate-backed designated requirement is what preserves TCC
> continuity. SideScreen shows the exact running path and provides Recheck /
> Copy Identity / Open Settings actions. After the first transition from an
> old ad-hoc build, remove or disable the stale Side Screen row in System
> Settings → Privacy & Security → Screen & System Audio Recording, then enable
> the exact bundle installed by `install_mac.sh` once. Future rebuilds should
> retain the grant. The preflight value is advisory: Start and configured
> auto-start still attempt capture, and the status changes to **Capture working**
> only after ScreenCaptureKit delivers the first frame. If capture setup fails,
> the host may remain listening and the status card names the actual failure.

> **⚠️ ADB Required**
> The Mac app needs `adb` to communicate with your Android device. If the app doesn't show "Running" after launch, you likely need to install ADB:
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
git clone https://github.com/tranvuongquocdat/SideScreen.git
cd SideScreen

# macOS (requires a valid Apple Development identity; ad-hoc signing is refused)
security find-identity -v -p codesigning
./scripts/build_mac.sh
./scripts/install_mac.sh --launch

# Android
cd AndroidClient && ./gradlew assembleDebug
```
</details>

---

## Usage

### USB mode (default — lowest latency)

1. Connect tablet to Mac via **USB-C**
2. Launch **Side Screen** on Mac (runs in menu bar — port forwarding is set up automatically)
3. Open **Side Screen** on tablet → keep on the **USB** tab → tap **Connect**
4. Done — drag windows to your new display

### Wireless mode (new in 0.8.0 — no cable)

1. Launch **Side Screen** on Mac → toggle to the **Wireless** tab → a QR code appears
2. Open **Side Screen** on tablet → switch to the **Wireless** tab → tap **Scan QR Code** → grant camera permission → aim at the QR on the Mac
3. The tablet remembers the Mac. On later launches, tap **Reconnect** when you want to start the session — no rescan and no background reconnect.

Wireless mode requires both devices to be on the same WiFi network. Local-only WiFi/hotspot routes are supported when the Mac is reachable on that LAN, and **5 GHz is strongly recommended** — 2.4 GHz can introduce noticeable jitter on dynamic content. If you need to revoke access, click **Reset Token (forget all)** on the Mac and re-pair each tablet.

USB mode remains the lowest-latency option for drawing or fast-paced gaming. Wireless adds 10–50 ms depending on WiFi quality.

For SDR USB sessions, the Android client uses a lightweight GPU color bridge when VSR is disabled. The measured Android sRGB tone profile is applied only after the decoder reports 8-bit full-range content; the normal 10-bit VideoRange path bypasses that curve because it already matches the native Android chart. The bridge adds no sharpening or reconnect, and it is a display correction—not a claim that streamed macOS pixels become native Android content.

For the closest native-like USB presentation, keep VSR sharpening off. The
unsharpened Bridge preserves the decoded pixel grid and applies only the
measured 8-bit Android tone correction. On the Tab S8+, the bridge also uses a
single external-texture pass for the native-sized `2800x1752` stream (the
Qualcomm decoder reports an 8-pixel block-aligned height, which is handled as
the panel crop) and nearest sampling for the general GPU path. CAS and SGSR1
are optional enhancement modes; they can make edges look more artificial than
the native Android launcher and are not the native-fidelity profile.

For the transport freshness and live latency-trace contract—including bounded
Mac sender admission, cross-device clock synchronization, and the dedicated
touch hot path—see [docs/transport-latency.md](docs/transport-latency.md).

### Experimental same-aspect Android final upscale (opt-in)

The private USB quality experiment can send a same-aspect `2560x1602` physical
source (`1280x801` logical HiDPI) and let the Android GPU upscale it into the
full `2800x1752` panel. The Android SurfaceView stays panel-sized, so the
experiment tests a real GPU scaler rather than a smaller letterboxed surface.
The bicubic bridge is selected only when the output surface is larger than the
decoded stream; an exact `2800x1752` stream bypasses it. The normal production
profile is unchanged when the override is absent.

For a controlled USB experiment, use the same 8-bit full-range sRGB profile on
both sides and cap the bridge at 60 FPS:

```bash
defaults write com.sidescreen.app SideScreen_exp_sourceResolution -string 1280x801
defaults write com.sidescreen.app SideScreen_exp_pixelFormat -string 8bit
defaults write com.sidescreen.app SideScreen_exp_profile -string main
defaults write com.sidescreen.app SideScreen_exp_colorSpace -string srgb
defaults write com.sidescreen.app SideScreen_exp_fps -int 60
```

Restart the canonical Mac host after changing the source-size key, disable VSR
on the tablet, and tap **Connect** manually. To restore the normal source and
10-bit profile, restore the regular defaults and remove the experiment keys:

```bash
defaults write com.sidescreen.app SideScreen_exp_pixelFormat -string 10bit
defaults write com.sidescreen.app SideScreen_exp_profile -string main10
defaults delete com.sidescreen.app SideScreen_exp_colorSpace
defaults delete com.sidescreen.app SideScreen_exp_sourceResolution
defaults delete com.sidescreen.app SideScreen_exp_fps
```

Restart the host after restoring these values. The experiment does not enable
automatic reconnect; tap **Connect** manually on the tablet.

The 2026-08-21 SM-X800 A/B run kept uniform color-chart error at `2.17` mean
RGB for both exact-size and upscaled output, but the 1–2 pixel text bars lost
contrast (about `255` to `210–214`). The upscaled bridge still held roughly
`56–58 FPS` with zero steady-state drops, but its measured GPU time was about
`10.5 ms` versus `~2 ms` for exact-size output. It is therefore a useful
quality experiment for video and larger UI, not the default for tiny desktop
text or battery-sensitive sessions.

The same-source native-launcher comparison also measured the Android bridge
renderer itself. With the new single-pass native-size path, RGB error fell from
`7.08` to `6.94` mean absolute error against the original `2800x1752` PNG, and
GPU postprocess time fell from roughly `3.3 ms` to `1.9–2.0 ms`. This measures
transport/presentation fidelity only; HEVC 4:2:0 compression and the Mac's
own rasterization still remain upstream limits.

### Headless mode (automatic operation and diagnostics)

In Settings → Startup, turn on **Launch at Login** and **Auto-start streaming on launch**, then pick the **Startup mode** (USB or Wireless). On your next login the server starts automatically — just open Side Screen on the tablet and tap Connect (USB) or Reconnect (Wireless).

First-time setup still needs a screen once to grant Screen Recording permission; after that the Mac runs fully headless. For wireless headless use, give the Mac a static IP or DHCP reservation, and consider enabling macOS Screen Sharing as a fallback way in.

For a diagnostic launch that must not steal focus or open Settings, run the
installed executable with `--headless`:

```bash
/Users/$USER/Applications/SideScreen.app/Contents/MacOS/SideScreen --headless
```

`SIDESCREEN_HEADLESS=1` is also accepted by direct executable launches. A
normal double-click/Finder/DMG launch does not use this mode: it keeps the
regular macOS app policy and opens the normal Settings window when appropriate.

### Objective visual, smoothness, and contention labs

The repository includes opt-in, measurement-first runners for the native
2800x1752 visual comparison, Android PixelCopy captures, raw frame pacing, and
W0-W5 Mac contention sampling. They preserve source/runtime provenance and do
not change the normal user path. See
[docs/eval/README.md](docs/eval/README.md) for the commands and the explicit
240-FPS camera and real-workload boundaries.

---

## Configuration

| Setting | Options | Default |
|---------|---------|---------|
| Resolution | 720p to 8K, 30+ presets + custom | 1920x1200 |
| Frame Rate | 30, 60, 90, 120 FPS | 120 |
| Bitrate | 20–5000 Mbps | 1000 Mbps |
| Quality | Ultra Low, Low, Medium, High | Ultra Low |
| HiDPI (Retina) | On/Off | Off |
| Gaming Boost | On/Off (1 Gbps, 120 Hz) | Off |
| Touch Input | On/Off | On |

Quality presets use bounded encoder targets. If a previous experiment set
`SideScreen_exp_bitrate`, that override intentionally wins over the bitrate
slider and quality picker; remove it with
`defaults delete com.sidescreen.app SideScreen_exp_bitrate` before comparing
those controls.

On this Apple Silicon target, the private 10-bit/Main10 experiment is capped at
60 FPS for stable output. Use the 8-bit/Main path when you need 120-FPS capture.

---

## Troubleshooting

<details>
<summary><strong>"SideScreen is damaged" on macOS</strong></summary>

This happens because the app is not notarized by Apple. Run this command to fix it:
```bash
sudo xattr -cr /Applications/SideScreen.app
```
Then open the app again.
</details>

<details>
<summary><strong>"Connection refused" on Android</strong></summary>

The Mac app sets up `adb reverse` automatically when streaming starts. If it still fails, make sure `adb` is installed (via Android SDK or Homebrew: `brew install android-platform-tools`) and your device has USB debugging enabled.
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
- If the Mac changes WiFi or its LAN IP, scan a fresh QR (the cached one points to the old address)
- macOS may prompt for **Local Network** permission on first wireless toggle — grant it; without it, LAN inbound is silently dropped
</details>

<details>
<summary><strong>Wireless: "Re-pair required" after restart / reinstall</strong></summary>

The Mac's auth token resets when you click **Reset Token (forget all)** or reinstall the app. Tap **Scan QR Code** on the Android client and scan the new QR shown on the Mac.
</details>

<details>
<summary><strong>Virtual display not appearing</strong></summary>

Screen Recording is still required for the virtual display: **System Preferences
→ Privacy & Security → Screen & System Audio Recording → Enable Side Screen**.
SideScreen does not use the Core Graphics preflight result as a start gate; if the
actual capture setup fails, use the inline recovery card to rebind the exact
installed bundle.
</details>

---

## Contributing

Contributions are welcome!

- ⭐ **Star** this repo to help others discover it
- 🐛 **Report bugs** via [Issues](https://github.com/tranvuongquocdat/SideScreen/issues)
- 💡 **Suggest features** via [Issues](https://github.com/tranvuongquocdat/SideScreen/issues)
- 🔧 **Submit PRs** — see [CONTRIBUTING.md](CONTRIBUTING.md)

---

## Support

If Side Screen is useful to you, consider supporting development:

<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/tranvuongqk)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=github-sponsors&logoColor=white)](https://github.com/sponsors/tranvuongquocdat)
[![VietQR](https://img.shields.io/badge/Vietnam-VietQR-DA251D?style=for-the-badge&logoColor=white)](https://sidescreen.dev/donate.html)

</div>

🇻🇳 Vietnamese users — scan VietQR for a local bank transfer (no international fees) at [sidescreen.dev/donate](https://sidescreen.dev/donate.html).

---

## License

[MIT License](LICENSE) — free for personal and commercial use.

---

<div align="center">

Made with ❤️ by **Tran Vuong Quoc Dat**

[Report Bug](https://github.com/tranvuongquocdat/SideScreen/issues) · [Request Feature](https://github.com/tranvuongquocdat/SideScreen/issues) · [Discussions](https://github.com/tranvuongquocdat/SideScreen/discussions)

</div>
