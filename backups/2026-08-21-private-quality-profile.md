# SideScreen private quality profile — 2026-08-21

This receipt records the verified private-repository state and the visual
quality experiment run on the Samsung Tab S8+ over the native USB path. It
contains no pairing tokens, credentials, or raw device logs.

## Repository state

```text
remote: git@github.com:tverma101/SideScreen.git
visibility: private, non-fork
branch: exp/quality-fork
GitHub Actions: disabled at repository level
workflow files: intentionally absent
```

The Android endpoint repair, Android semantic dark palette, and this receipt
are on the private `exp/quality-fork` branch. The corresponding branch and
`main` were pushed after hosted Actions were disabled. Local validation is the
only CI path for this repository.

## Active stream profile

```text
Mac logical display: 1400x876 HiDPI
encoded/display pixels: 2800x1752 -> 2800x1752 (1:1)
capture cadence: 120 Hz (SideScreen_exp_fps unset)
codec: HEVC Main10
capture format: 10-bit 420 video-range
experimental target: 75 Mbps average / 112 Mbps per-second cap
GOP: 1 second
B-frames: disabled
Android post-process: CAS, sharpness 0.70, edge threshold 0.02
USB: video 54321, control 54322, adb reverse
```

The UI `SideScreen_quality=ultralow` label is retained for compatibility; the
experimental bitrate override is the effective rate-control target. The
encoder deliberately does not set VideoToolbox Quality mode because earlier
tests showed it could ignore bitrate limits and overload the tablet decoder.

## Visual captures

The comparison images are saved as Codex outputs:

- `sidescreen-android-home.png`: native Android Home screen at 2800x1752.
- `sidescreen-android-stream-after-home.png`: streamed Mac desktop at the
  same panel resolution.
- `sidescreen-android-direct-ab.png` and `sidescreen-android-cas-ab.png`:
  same-scene direct/CAS captures.
- `sidescreen-android-color-profile.png`: Android semantic palette/settings
  capture.

The terminal could not create a direct macOS display screenshot because its
Screen Recording permission was not granted. The stream captures are valid
Android-side output images; direct-vs-CAS is an output A/B, not a claim of a
pixel-identical source screenshot.

## Live evidence

The 120-Hz profile passed the held-cursor motion test on the virtual display:

- Mac pipeline: approximately 106–109 FPS, 14–15 Mbps, frame age about
  9–16 ms, host-reported drops 0.
- Android: zero decoder drops and zero input-buffer timeouts during the
  steady-state motion window; control RTT about 3–5 ms.
- CAS: approximately 73–91 FPS, about 2.5 ms post-process time, and no
  decoder failure signatures.

A reversible 90-Hz cadence test was also run. It remained stable, but delivered
only about 84–85 FPS under motion with frame age around 20–25 ms, so it was
rejected and `SideScreen_exp_fps` was restored to unset/120-Hz behavior.

The first reconnect after restarting the host had one expected stale-frame
drop while waiting for a keyframe; subsequent steady-state windows returned
to zero drops. This is recorded separately from live stability rather than
being presented as a clean restart with no transient.

## Quality conclusion

The semantic Android color profile is retained: dark graphite surfaces,
readable light text, cyan controls, and explicit success/warning/error tokens
are visually coherent on the tablet. CAS is retained as the experimental
display-side path because it adds controlled edge/chroma reconstruction at a
small measured GPU cost and passed motion stability.

The direct and CAS wallpaper captures are visually close. This does not prove
Android-native glyph sharpness: the Mac side sends already-rasterized macOS
pixels through compatible 4:2:0 HEVC. Re-rendering arbitrary macOS UI as native
Android text would require a different semantic/vector-remoting architecture,
not another small bitrate or sharpening slider.
