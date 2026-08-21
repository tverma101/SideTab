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

## Android connection safety change

The current Android working tree is now manual-connect only for screen
sharing. It does not resume a saved USB session on launch, retry a dropped or
failed video connection, or probe the Mac listener from the idle checklist.
The optional control channel makes one best-effort connection per explicit
video session and falls back in-band instead of retrying after EOF. The idle
UI shows ADB/USB readiness separately from the Mac server, which is checked
only after the user taps Connect.

This change was locally built and unit-tested but intentionally not installed
or launched on the tablet in this pass, per the no-reconnect boundary.

## Android battery audit

The Android source had three avoidable power costs: a partial
`SideScreen::PerformanceMode` wake lock acquired at Activity startup, a
`KEEP_SCREEN_ON` window flag that remained set on the idle screen, and decoder
/VSR resources that were retained after a stream drop. The working tree now
keeps the screen awake only while streaming in the foreground, releases the
video pipeline on disconnect, removes the unused `WAKE_LOCK` permission, and
defaults background auto-disconnect to 60 seconds.
The two-second latency ping loop is also paused while the Activity is in the
background and resumes only for a still-visible stream. High-frequency PONG
and fallback dispatch diagnostics remain available in logcat but are persisted
to the app-private file only once per ten seconds; the idle local checklist
refreshes every ten seconds as well.

A read-only tablet power snapshot also showed the device-level “stay awake
while plugged in” setting enabled; that is separate from the app and was not
changed. CAS/VSR at 120 Hz remains an intentional active-stream GPU cost and
can be disabled in Android settings when battery runtime matters more than
post-processing quality.

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

## Android SDR color profile — 2026-08-21 continuation

The Android client now includes a reversible `Android sRGB / BT.709 Chroma
Balance` profile for the GPU display path (CAS, SGSR1, Bridge, and CfL). It
preserves luma and neutral gray by applying a neutral-anchored 2x2 correction
only to centered Cb/Cr after decode. This targets the measured 4:2:0 chroma
bias without applying a generic saturation or brightness boost.

Offline A/B fitting against the saved O0 2800x1752 sRGB color chart changed
ΔE76 mean from 3.89 to 2.80 and the maximum from 13.42 to 9.89. The saved
text and grayscale-gradient pairs were unchanged by the anchored transform.
The profile is enabled by default when the GPU path is active, can be
disabled from Android Display Settings, and can be A/B switched with the
private `VSR_CMD` broadcast. The direct decoder-to-Surface path remains
unchanged for lower battery use. This continuation was built and installed on
the connected tablet, but the live stream was intentionally not reconnected;
runtime shader execution therefore remains a separately authorized check.
