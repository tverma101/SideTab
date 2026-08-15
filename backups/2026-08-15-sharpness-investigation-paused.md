# SideScreen 120 Hz Android sharpness investigation — paused record

Date: 2026-08-15

This is the superseding record for the 2026-08-15 SideScreen recovery and
sharpness campaign. It documents the source changes, runtime settings, test
method, rejected experiments, physical user verdicts, and recoverable Git
history. The Git commit containing this file is the authoritative full-source
backup for both `MacHost` and `AndroidClient` at the pause point.

The older files `2026-08-15-native-usb-baseline.md` and
`2026-08-15-android-stable-profile.md` remain historical evidence. In
particular, the latter records an intermediate 60 Hz / 0.90 encode-scale
profile and is not the final paused configuration.

## Status at pause

- Further quality experiments are paused at the user's request.
- The macOS SideScreen process and Android SideScreen activity were stopped.
- The rejected QP-20 encoder experiment was removed from source.
- The rejected Android native-sharpen shader was removed from source.
- The installed macOS bundle was rebuilt from the paused source, ad-hoc signed,
  and left stopped.
- The Android APK was rebuilt from the paused source. The installed Android app
  was left stopped.
- No CAS processing was used as the restored baseline. CAS and SGSR remain
  optional existing modes in the project, but `vsr_enabled=false` bypasses the
  complete GPU post-processing path.

## Goal and acceptance boundary

The requested target was:

1. restore the responsive USB screen-share behavior seen the previous day;
2. keep actual motion throughput above 100 FPS rather than capping at 60 FPS;
3. pass a held-left-button, rapidly-spinning cursor test without visual
   glitching, HEVC reference-chain failures, or input-buffer drop cascades; and
4. make the streamed desktop look materially sharper on Android, approaching
   the apparent sharpness of Android-native rendering.

Automated counters were used only for transport and decoder health. The user's
physical observation of the tablet remained authoritative for perceived lag,
glitching, and sharpness.

## Hardware and software boundary

```text
Android device: Samsung SM-X800 (Galaxy Tab S8+)
Android version: 16
Physical panel: 1752x2800 (landscape 2800x1752)
Reported density: 340 dpi
Mac stream codec: HEVC Main, hardware VideoToolbox encoder
Android path: MediaCodec hardware decode directly to SurfaceView
Transport: USB loopback through adb reverse
Video port: 54321
Control port: 54322
```

The tablet hardware decoder supports the ordinary HEVC Main/Main10 path used
by the app. HEVC 4:4:4 was not a viable baseline because the Android hardware
decoder does not expose a compatible 4:4:4 decode path.

## Authoritative paused runtime settings

These values are intentionally limited to display/transport settings. Pairing
tokens, device identities, and other secrets are not included in this backup.

### macOS `com.sidescreen.app`

```text
SideScreen_resolution=1400x876
SideScreen_customWidth=1400
SideScreen_customHeight=876
SideScreen_hiDPI=1
SideScreen_encodeScale=1
SideScreen_refreshRate=120
SideScreen_quality=high
SideScreen_bitrate=8000
SideScreen_connectionMode=usb
SideScreen_rotation=0
SideScreen_flipHorizontal=0
SideScreen_flipVertical=0
SideScreen_forceStart=1
```

At HiDPI, 1400x876 produces a physical 2800x1752 capture, exactly matching the
tablet's landscape panel. `encodeScale=1` prevents source downscaling. The UI
bitrate setting remains 8000, while `VideoEncoder.swift` applies its existing
non-gaming minimum target of 60 Mbps; observed VBR traffic depends heavily on
motion and was commonly about 14 Mbps when mostly static and 26-35 Mbps during
the rapid-circle workload.

Restore the non-secret Mac settings with:

```sh
defaults write com.sidescreen.app SideScreen_resolution -string 1400x876
defaults write com.sidescreen.app SideScreen_customWidth -int 1400
defaults write com.sidescreen.app SideScreen_customHeight -int 876
defaults write com.sidescreen.app SideScreen_hiDPI -bool true
defaults write com.sidescreen.app SideScreen_encodeScale -float 1
defaults write com.sidescreen.app SideScreen_refreshRate -int 120
defaults write com.sidescreen.app SideScreen_quality -string high
defaults write com.sidescreen.app SideScreen_bitrate -int 8000
defaults write com.sidescreen.app SideScreen_connectionMode -string usb
defaults write com.sidescreen.app SideScreen_rotation -int 0
defaults write com.sidescreen.app SideScreen_flipHorizontal -bool false
defaults write com.sidescreen.app SideScreen_flipVertical -bool false
```

### Android app preferences

```text
vsr_enabled=false
vsr_mode=bridge
vsr_sharpness=0.4
vsr_edge_threshold=0.02
```

Only `vsr_enabled=false` affects the paused video path. `bridge`, sharpness, and
edge-threshold are inactive saved values. With the activity running, the safe
direct path can be restored using:

```sh
adb shell am broadcast -a com.sidescreen.app.VSR_CMD \
  --ez enabled false --es mode bridge --ef sharpness 0.4 \
  --ef edge_threshold 0.02
```

## Source changes retained at the pause point

### Android direct-pixel mapping

`MainActivity.kt` centers a near-native direct stream at its encoded pixel
size instead of allowing SurfaceFlinger to resample it. At the final
1400x876-HiDPI configuration the stream and panel are both exactly 2800x1752,
so no border or scaling remains. Lower-resolution streams and explicitly
enabled GPU modes continue to use their normal fill behavior.

### Android HEVC input pacing

`VideoDecoder.kt` waits up to 25 ms for a MediaCodec input buffer rather than
treating a normal hardware hand-off race as a lost HEVC frame after 17 ms. A
false P-frame discard invalidated the reference chain and previously caused a
forced-IDR/drop cascade. The 25 ms bound did not add a steady display queue; it
provided bounded socket backpressure only when the codec briefly exhausted its
input buffers.

### Android optional VSR diagnostics

`SgsrRenderer.kt` reports rendered FPS in its diagnostic summary. Its SGSR1
sharpness control now maps the normalized 0..1 UI value to the algorithm's
documented 0..2 edge-sharpness range. This code is inactive in the paused
baseline because VSR is disabled. CAS was not selected or used to establish
the baseline.

### Exact encoded-size negotiation

`AppDelegate.swift` advertises the actual encoded dimensions after codec
negotiation. Android therefore sizes MediaCodec and its render surface from the
stream that is really sent, rather than from a logical HiDPI dimension.

### Capture geometry telemetry

`ScreenCapture.swift` logs the first ScreenCaptureKit frame's pixel-buffer
size, content rectangle, content scale, and display scale factor. This made
logical/physical-size mistakes observable without changing the frame path.

## Attempt ledger

### 1. Native USB/control-path restoration

- Recovery commit: `80e6176` (`backup: restore native USB baseline and control path`).
- Restored separate video/control connections, USB loopback behavior, display
  settings, and a recoverable baseline note.
- Screen Recording approval already existed. Permission prompts were not the
  cause of the later sharpness issue.
- CAS was not part of the previous day's working path and was kept out of the
  restored baseline.

### 2. Bounded High-preset quality increase

- Commit: `2f1aecc` (`quality: raise high preset by a bounded increment`).
- VideoToolbox High quality moved from 0.90 to 0.92.
- A prior 0.95 trial overloaded the live USB/decoder path; 1.0 could be
  potentially lossless but was not safe for this real-time configuration.
- Physical result at 0.92: still soft; retained because it was stable and a
  bounded improvement over 0.90.

### 3. External E3 transport snapshot

- Commit: `ce8cc01` (`backup: snapshot external E3 transport fixes`).
- Preserved external relay/forwarder work. It is a recovery artifact and does
  not establish screen sharpness.

### 4. Initial Android stable profile at 60 Hz / 0.90 scale

- Commit: `49a9e85` (`fix(android): pace high-motion decode without HEVC tears`).
- Intermediate settings were 1400x876 HiDPI, encode scale 0.90, and 60 Hz.
- Two automated circle tests passed without decoder drops or keyframe loss.
- This profile fixed tearing but did not meet the later-restated requirement
  that the real baseline exceeded 100 FPS. It is preserved only as an
  intermediate recovery point.

### 5. Restore greater-than-100-FPS operation

- Refresh was restored from 60 Hz to 120 Hz.
- During actual rapid cursor motion, capture/encode and decode rose above 100
  FPS; lower idle readings reflected a mostly static ScreenCaptureKit source,
  not a 60 FPS cap.
- The held-circle test became the required regression gate after every
  material candidate.

### 6. 1386x867 logical / 2772x1734 physical exact-pixel experiment

- Used 1386x867 HiDPI to produce 2772x1734 and centered it one-to-one inside
  the 2800x1752 Android surface.
- This removed fractional resampling at the cost of a 14-pixel horizontal and
  9-pixel vertical border on each side.
- At 115 Hz, the decoder measured about 101.9 FPS with zero failure
  signatures.
- Physical result: no noticeable sharpness gain. The experiment was
  superseded by the screenshot-authentic 1400x876 geometry.

### 7. BGRA ScreenCaptureKit capture format

- Tested a BGRA source path to avoid an early YUV conversion.
- Result: pipeline throughput fell to roughly 70 FPS and repeated reconnects
  appeared.
- Rejected and reverted. The final capture path does not use BGRA.

### 8. VideoToolbox QP-18 frame-level experiment

- Tested a QP-18 encoder hint as a possible way to preserve text edges.
- The encoder accepted the request, but the compared luma result was unchanged
  in the captured A/B sample (the same 0.936994 Y similarity result was
  observed before and after).
- Physical result: no useful improvement. Rejected and reverted.

### 9. Host CPU/vImage luma sharpening

- Tested approximately 25% luma sharpening before VideoToolbox.
- The additional high-frequency content made the HEVC stream harder to encode
  and decode, producing immediate keyframe/drop cascades.
- Rejected. The source file created for this path was deleted; no host luma
  sharpening remains.

### 10. Android post-decode Native Sharp at 30%

- Added a five-tap luminance unsharp fragment shader after MediaCodec decode.
- Used four neighboring luma samples, an edge gate, and a bounded boost to
  avoid strong halos. This was a custom shader, not CAS.
- Effective gain was about 30% (`sharpness=0.4`, multiplied by 0.75).
- Automated 120 Hz motion result: about 108.5 FPS, zero drop/keyframe failure
  signatures, and roughly 2-3 ms GPU processing.
- Physical result: no noticeable sharpness improvement.

### 11. Android post-decode Native Sharp at 60%

- Increased only the custom shader gain (`sharpness=0.8`, approximately 60%
  effective gain), retaining the halo clamp.
- Automated motion stayed above 100 FPS and counters still showed no drops.
- Physical result: the display felt more laggy and did not provide an
  acceptable sharpness improvement.
- Rejected. The mode, shader, settings labels, and mappings were removed from
  source rather than merely disabled.

### 12. Screenshot-authentic 1400x876 HiDPI direct baseline

- Restored the exact resolution shown in the original screenshot.
- ScreenCaptureKit geometry was verified as:

  ```text
  logical display: 1400x876
  physical pixel buffer: 2800x1752
  contentRect: 1400x876
  contentScale: 1
  scaleFactor: 2
  Android surface: 2800x1752
  mapping: 1:1
  ```

- Clean-source held-circle result after reinstalling Android: 110.2 FPS with
  zero input-buffer, stale-output, or waiting-for-keyframe signatures.
- Physical result: responsive, but sharpness still looked like the previous
  day's baseline rather than materially better.
- This geometry and direct path form the paused baseline.

### 13. VideoToolbox session-level MaxAllowedFrameQP=20

- Verified at runtime that the Mac HEVC hardware encoder advertises and accepts
  `kVTCompressionPropertyKey_MaxAllowedFrameQP` at 2800x1752/120 Hz.
- The live encoder logged `MaxAllowedFrameQP=20 status=0`.
- Held-circle result: 109.6 FPS over the measured decoder span, zero reported
  drops, zero timeouts, and zero keyframe failure signatures.
- Physical result: looked the same.
- Rejected and removed from source. The installed macOS bundle was rebuilt
  without the QP cap before pausing.

## Final measured direct-path evidence

The last accepted transport-only test before the final QP experiment used the
paused 1400x876 HiDPI direct configuration:

```text
decoder output: 110.2 FPS (1020 frames / 9.259 seconds)
failure signatures: 0
stream: 2800x1752 HEVC Main
Android mapping: 2800x1752 -> 2800x1752, 1:1
VSR/CAS/SGSR: disabled
```

During motion, typical host frame age was about 8-10 ms with zero host-reported
drops. Idle FPS was lower because ScreenCaptureKit did not continuously deliver
120 unique frames for an unchanged desktop.

## Why the image still looked soft

After the final geometry restoration there was no remaining resolution or
SurfaceFlinger scaling mismatch to remove. The direct stream was already
pixel-for-pixel aligned with the tablet panel. The remaining softness is most
consistent with two limits of framebuffer video remoting:

1. macOS rasterizes its own grayscale-antialiased text; Android receives those
   rasterized pixels rather than Android-native glyphs; and
2. the compatible real-time HEVC Main path uses chroma-subsampled video coding
   and in-loop processing designed for video rather than lossless desktop UI.

Increasing normal quality, bounding QP, and adding post-decode sharpening did
not cross the user's visible acceptance threshold. Therefore further small
resolution, bitrate, or slider changes should not be presented as likely fixes.

## Remaining materially different options

These were identified but not implemented at the pause point:

1. A small edge-selective Metal prefilter on the Mac before VideoToolbox. This
   could create visible edge contrast while leaving Android on direct decode,
   but it must be rate-aware because the CPU/vImage prototype caused HEVC
   complexity and keyframe cascades.
2. A controlled H.264 High-profile A/B at high bitrate. It may treat desktop
   edges differently, but it risks higher bandwidth and losing the current
   greater-than-100-FPS result.
3. Semantic/vector remoting that re-renders supported UI or text on Android.
   This is the only route to genuinely Android-native glyph sharpness, but it
   is a different architecture and cannot reproduce arbitrary macOS apps as a
   simple second display.

HEVC Main10 may improve gradients and banding but is not expected to materially
sharpen text. HEVC 4:4:4, lossless 1.0 quality, and another Android post-process
pass were ruled out by decoder compatibility, overload, or physical latency.

## Reproduction test

The stress test moves a held left mouse button through 960 points, completing a
circle every 30 points at an 8.333 ms event interval:

```sh
swift -e 'import CoreGraphics; import Foundation
let center = CGPoint(x: -740, y: 998)
let radius = 260.0
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: center, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(100_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: center, mouseButton: .left)!.post(tap: .cghidEventTap)
for i in 0..<960 {
    let a = Double(i) * 2.0 * Double.pi / 30.0
    let p = CGPoint(x: Double(center.x) + radius * cos(a),
                    y: Double(center.y) + radius * sin(a))
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
            mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(8_333)
}
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: center, mouseButton: .left)!.post(tap: .cghidEventTap)'
```

Android failure signatures checked after each run:

```text
Dropping frame (no input buffer after ...)
waiting for keyframe
Dropping stale output frame
```

Startup-only reconnects while replacing/restarting an app were excluded from a
marked steady-state stress interval. User-visible physical motion remained the
final acceptance boundary even when all counters passed.

## Validation at pause

```text
MacHost: swift test
Result: 35 tests passed, 0 failures

MacHost: swift build -c release
Result: succeeded

AndroidClient: ./gradlew assembleDebug testDebugUnitTest
Result: BUILD SUCCESSFUL

macOS installed bundle: codesign --verify --deep --strict
Result: succeeded
```

Paused artifact fingerprints:

```text
Installed macOS executable SHA-256:
bbbf8aa295f36e10e5133ce8a8a9817a59198819387fdfa5cb7cb0ee9200c990

Android debug APK SHA-256:
9240f226c4e8b6d1b40bde410e90678b9cf6121668f53514e2171b37f7b8703a
```

## Recovery history

```text
80e6176  backup: restore native USB baseline and control path
2f1aecc  quality: raise high preset by a bounded increment
ce8cc01  backup: snapshot external E3 transport fixes
49a9e85  fix(android): pace high-motion decode without HEVC tears
```

The commit containing this document supersedes the runtime profiles in the two
older backup notes and captures the final retained Mac source, Android source,
and diagnostic settings record. No generated build directory, local pairing
secret, raw logcat dump, or user credential is included.
