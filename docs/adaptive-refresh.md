# Adaptive refresh contract

SideScreen must treat the configured display refresh rate as a **ceiling**, not a permanent capture rate.

## Non-negotiable behavior

- Static/read-only content must decay from 60 -> 30 -> 15 -> 8 FPS.
- A blinking caret/cursor-sized dirty region must not keep the stream hot.
- Direct input must pre-wake the capture path before a low idle cadence can add visible latency:
  - scroll/drag: session ceiling (up to 120 FPS)
  - key/click: up to 60 FPS
- Broad sustained motion normally runs at 60 FPS.
- A session above 60 FPS is a burst/validated state, not the default.
- 60-FPS video must settle at 60 FPS. A short >60-FPS probe is allowed, but it must fail closed and cool down when broad dirty frames do not arrive faster than ~74 Hz.
- True high-cadence broad motion may remain at the session ceiling after validation.
- The existing wireless 60-FPS ceiling is authoritative.
- ScreenCaptureKit `.idle` frames are discarded before dither, HDR conversion, hashing, encode, and network send.
- The default adaptive path must use ScreenCaptureKit frame metadata (`SCFrameStatus`, `dirtyRects`), not whole-frame hashes.
- Rate increases are immediate; rate decreases use hysteresis so the stream does not visibly flap between tiers.

## Implementation map

- `AdaptiveRefreshPolicy.swift`: deterministic state machine. No ScreenCaptureKit dependency.
- `AdaptiveRefreshController.swift`: reads ScreenCaptureKit metadata, observes input, serializes live `SCStream.updateConfiguration` calls, and advances idle decay when ScreenCaptureKit goes silent.
- `ScreenCapture.swift`: owns the controller and exits early on ScreenCaptureKit idle frames.
- `AdaptiveRefreshPolicyTests.swift`: deterministic acceptance tests.
- `scripts/benchmark-adaptive-refresh.sh`: repeatable SideScreen + WindowServer CPU sampler for A/B runs.

## Debug escape hatch

Adaptive refresh is default-on. To compare with the old fixed-FPS path:

```bash
defaults write com.sidescreen.host SideScreen_adaptiveRefresh -bool false
```

Use the actual app bundle identifier if it differs. Re-enable by setting the key to `true` or deleting the override.

The legacy SHA-based `FrameSkipper` is intentionally kept out of the default adaptive path. It may be used only for controlled fixed-FPS experiments.

## Hardware performance gate before merge

Run the same resolution, codec, bitrate/quality, transport, and tablet build for both the canonical branch and the adaptive branch. Warm each case before sampling.

| Scenario | Expected adaptive tier | SideScreen CPU | WindowServer CPU | Encode/send FPS | Visual notes |
|---|---:|---:|---:|---:|---|
| Static terminal, no input | 8 | | | | |
| Terminal typing | 60 while typing, decay after | | | | |
| Static document + caret blink | 8-15 | | | | |
| Web scrolling / drag | 60-120 | | | | |
| 30-FPS video | <=60 | | | | |
| 60-FPS YouTube | 60 after probe | | | | |
| High-cadence animation | up to session ceiling | | | | |

For each row, sample the same duration on both branches. Example:

```bash
./scripts/benchmark-adaptive-refresh.sh static-terminal 30 results/static-terminal.csv
```

The CSV records branch/commit/macOS/hardware plus one-second SideScreen and WindowServer CPU samples. Also retain SideScreen logs containing `Adaptive refresh:` so the measured CPU can be tied to the actual tier selected by the governor.

A CPU/power win does **not** justify visible latency, dropped interaction, decoder instability, or degraded image quality. A smoothness win does **not** justify pinning an unchanged desktop at 120 FPS.

## Virtual-display refresh is a separate measurement

The USB `CGVirtualDisplay` may still advertise/run a 120 Hz display mode so macOS can generate true high-cadence content. Do not couple its mode directly to the capture governor. Core Graphics display-mode switching is synchronous and can change display parameters; rapid mode switching could create more instability than it saves.

Issue #3 owns the isolated 60-vs-120 WindowServer experiment. Only consider coarse virtual-display mode adaptation if that measurement proves the display mode itself remains a significant static cost after capture adaptation.

## Regression rules for future changes

Any change to cadence thresholds, ScreenCaptureKit configuration, frame skipping, encoder scheduling, or input handling must:

1. Preserve the session/wireless caps.
2. Add or update deterministic policy tests.
3. Re-run the hardware matrix above when the change can affect capture cadence or latency.
4. Keep an A/B path until the hardware result is recorded.
5. Never claim a performance improvement from frame skipping alone if ScreenCaptureKit is still capturing at the old high cadence.
