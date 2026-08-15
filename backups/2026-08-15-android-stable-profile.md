# SideScreen Android stable profile — 2026-08-15

This is the runtime profile that passed the rapid held-cursor circle stress
test after reinstalling the Android APK. The earlier
`2026-08-15-native-usb-baseline.md` remains the immutable pre-tuning snapshot;
its 2800x1752 at 120 Hz profile is not the verified stable profile.

The Git commit containing this file and `VideoDecoder.kt` is the recoverable
source snapshot for both `MacHost` and `AndroidClient`. Earlier source backups
are commits `80e6176`, `2f1aecc`, and `ce8cc01`.

## Verified Mac host settings

```text
SideScreen_resolution=1400x876
SideScreen_hiDPI=1
SideScreen_encodeScale=0.90
SideScreen_quality=high
SideScreen_bitrate=8000
SideScreen_gamingBoost=0
SideScreen_controlPort=54322
SideScreen_port=54321
SideScreen_refreshRate=60
SideScreen_touchEnabled=1
SideScreen_forceStart=1
```

The virtual display remains HiDPI at 2800x1752 physical pixels. The 0.90
transport scale encodes 2520x1576 pixels, or 81% of the native pixel count.
The high preset maps to VideoToolbox quality 0.92. This keeps the sharper
quality increment while leaving enough Android hardware-decoder headroom for
rapid full-screen motion.

Restore the Mac values with:

```sh
defaults write com.sidescreen.app SideScreen_resolution -string 1400x876
defaults write com.sidescreen.app SideScreen_hiDPI -bool true
defaults write com.sidescreen.app SideScreen_encodeScale -float 0.90
defaults write com.sidescreen.app SideScreen_quality -string high
defaults write com.sidescreen.app SideScreen_bitrate -int 8000
defaults write com.sidescreen.app SideScreen_gamingBoost -bool false
defaults write com.sidescreen.app SideScreen_controlPort -int 54322
defaults write com.sidescreen.app SideScreen_port -int 54321
defaults write com.sidescreen.app SideScreen_refreshRate -int 60
defaults write com.sidescreen.app SideScreen_touchEnabled -bool true
defaults write com.sidescreen.app SideScreen_forceStart -bool true
```

Restart SideScreen after restoring the values.

## Verified Android client settings

```text
vsr_enabled=false
vsr_mode=BRIDGE_ONLY
vsr_sharpness=0.8
overlay_x=2010.0
overlay_y=34.0
```

`vsr_enabled=false` is mandatory for this profile. CAS, SGSR, and the bridge
post-processing path are all disabled; MediaCodec renders directly to the
Android display surface. `BRIDGE_ONLY` is only the saved inactive mode and is
not evidence that CAS was used.

With the Android activity running, restore the video-path values with:

```sh
adb shell am broadcast -a com.sidescreen.app.VSR_CMD \
  --ez enabled false --es mode BRIDGE_ONLY --ef sharpness 0.8
```

## Installed artifact fingerprints

```text
Mac SideScreen executable SHA-256:
02d1b33052569a1f8ae5df7babf76a5b182a5bfe8f682c9834eb8d723b451b70

Android 0.11.1 debug APK SHA-256:
c1113a901cbe6c16732c1035fbc3cd5aa1769a14997ce2e5ac9951117c84f523
```

## Acceptance evidence

Two separate eight-second tests each injected 480 left-button-held cursor
positions in rapid circles on the SideScreen virtual display. The second test
was run after a clean `adb install -r` of the rebuilt APK.

- Stream crop: 2520x1576 (`0,2519,0,1575`).
- Android decoder: zero dropped frames and zero 17 ms input-buffer timeouts.
- HEVC continuity: no waiting-for-keyframe drops.
- Decoder latency during motion: about 8-10 ms average, 28 ms maximum.
- Control RTT during motion: about 2-4 ms.
- Android read-loop callback work: about 1-2 ms.
- CAS/SGSR processing: disabled.

This is automated evidence for the reproduced stress pattern. The physical
tablet test remains the final user-visible acceptance boundary.
