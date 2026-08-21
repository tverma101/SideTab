# SideScreen wireless efficiency profile — 2026-08-21

## Scope

The experimental `exp/quality-fork` branch keeps USB behavior unchanged and
adds a bounded profile for explicit wireless sessions. Wireless remains the
existing authenticated TCP video protocol plus its separate TCP control
channel; no UDP/QUIC rewrite or background reconnect was introduced.

## Contract

- Mac virtual display, ScreenCaptureKit cadence, and VideoToolbox expected frame
  rate are forced to 60 FPS for wireless.
- The cap is applied after the existing `SideScreen_exp_fps` override, so a
  stale 90/120-FPS experiment cannot bypass the wireless limit. USB keeps its
  prior experiment behavior.
- The Android decoder uses a 60 FPS operating target for wireless even on a
  120 Hz physical panel.
- Wireless encoding is capped at a 40 Mbps average target. The existing
  VideoToolbox 1.5x one-second data-rate limit therefore bounds the peak at
  approximately 60 Mbps.
- Android binds video and the optional control socket to the same selected WiFi
  route. A local-only WiFi route is eligible; requiring internet validation
  would reject some direct LAN/hotspot setups.
- No TCP keepalive, automatic reconnect, or hosted GitHub Actions were added.

## Validation

- `cd MacHost && swift test` — 38 tests passed.
- `cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon` —
  build successful.
- Device E2E for this revision is pending: the Samsung tablet disappeared from
  `adb devices` before the post-change APK could be installed. The existing
  installed build was tested earlier over USB, but that is not evidence for the
  new wireless profile.
