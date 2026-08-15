# SideScreen native USB baseline — 2026-08-15

This file records the recoverable baseline before the next Android sharpness
increment. The Git commit containing this file is the authoritative source
snapshot for both `MacHost` and `AndroidClient`.

## Mac host settings

```text
SideScreen_resolution=1400x876
SideScreen_hiDPI=1
SideScreen_encodeScale=1
SideScreen_quality=high
SideScreen_bitrate=8000
SideScreen_gamingBoost=0
SideScreen_controlPort=54322
SideScreen_port=54321
SideScreen_refreshRate=120
SideScreen_touchEnabled=1
SideScreen_forceStart=1
```

The 1400x876 HiDPI display is captured and encoded at its physical
2800x1752 panel resolution. `encodeScale=1` means there is no source downscale.

## Android client settings

```text
vsr_enabled=false
vsr_mode=BRIDGE_ONLY
vsr_sharpness=0.8
overlay_x=2010.0
overlay_y=34.0
```

`vsr_enabled=false` is the important baseline boundary: SGSR/CAS processing is
off, and MediaCodec renders the native HEVC output directly to the display
surface.

## Installed artifact fingerprints

```text
Mac SideScreen executable SHA-256:
884a4abdf0b5c583643c0a5aff916d8b734cd151dfc604fa0f3af947c32ec63c

Android debug APK SHA-256:
dbe245731c035823367a8b4bc9b63585eb39e33283026a7e03b60bf50e8504e0
```

## Live verification

- macOS ScreenCaptureKit stream: 2800x1752 at 120 fps requested.
- Android decoder crop: 2800x1752 (`0,2799,0,1751`).
- Dedicated control channel stayed active beyond the previous 11-second
  failure boundary.
- A synthetic hold plus four rapid circles delivered all 240 move samples to
  both the Mac control receiver and the main-thread gesture handler while the
  video pipeline reported zero dropped frames.
