# Adaptive refresh contract

SideScreen must treat the configured display refresh rate as a **ceiling**, not a permanent capture rate.

## Non-negotiable behavior

- Static/read-only content must decay from 60 -> 30 -> 15 -> 8 FPS, and a
  silent ScreenCaptureKit stream must not be kept alive by re-encoding the
  cached full frame.
- A blinking caret/cursor-sized dirty region must not keep the stream hot.
- Direct input must pre-wake the capture path before a low idle cadence can add visible latency:
  - scroll/drag: session ceiling (up to 120 FPS)
  - key/click: up to 60 FPS
- Broad sustained motion normally runs at 60 FPS.
- A session above 60 FPS is a burst/validated state, not the default.
- 60-FPS video must settle at 60 FPS. A short >60-FPS probe is allowed, but it must fail closed and cool down when broad dirty frames do not arrive faster than ~74 Hz.
- True high-cadence broad motion may remain at the session ceiling after validation.
- The existing wireless 60-FPS ceiling is authoritative.
- The effective capture ceiling is also the virtual-display mode: USB Main10
  is negotiated at 60 FPS, while an 8-bit/Main USB session may retain its
  requested 120-FPS ceiling. A display mode that is faster than capture is
  treated as avoidable WindowServer work.
- ScreenCaptureKit `.idle` frames are discarded before dither, HDR conversion, hashing, encode, and network send.
- The default adaptive path must use ScreenCaptureKit frame metadata (`SCFrameStatus`, `dirtyRects`), not whole-frame hashes.
- Rate increases are immediate; rate decreases use hysteresis so the stream does not visibly flap between tiers.
- A warm decay observation cannot re-promote a stream that has just been demoted; promotion requires new UI/broad motion or direct interaction.
- The silent-stream policy watchdog runs at 1 Hz. It advances the policy clock
  only; it does not inspect pixels or encode a keepalive frame.

## Implementation map

- `AdaptiveRefreshPolicy.swift`: deterministic state machine. No ScreenCaptureKit dependency.
- `AdaptiveRefreshController.swift`: reads ScreenCaptureKit metadata, observes input, serializes live `SCStream.updateConfiguration` calls, and advances idle decay when ScreenCaptureKit goes silent.
- `ScreenCapture.swift`: owns the controller and exits early on ScreenCaptureKit idle frames.
- `ScreenCapture.swift`: suppresses cached full-frame keepalives by default;
  set `SideScreen_exp_idleKeepalive=true` only for a diagnostic comparison.
- `AdaptiveRefreshPolicyTests.swift`: deterministic acceptance tests.
- `scripts/benchmark-adaptive-refresh.sh`: repeatable SideScreen + WindowServer CPU sampler for A/B runs.
- `scripts/run-capture-source-benchmark.sh`: installed-bundle, same-display callback check for ScreenCaptureKit versus Core Graphics. It records callback cadence and non-empty buffers; it does not measure transport latency or re-enable the production CG fallback.

## Debug escape hatch

Adaptive refresh is default-on. SideScreen variants currently share the `com.sidescreen.app` defaults domain, so use a known full app/binary path and verify its PID when doing A/B work; do not identify a running experiment by bundle ID alone.

Disable adaptive refresh for the fixed-FPS comparison:

```bash
defaults write com.sidescreen.app SideScreen_adaptiveRefresh -bool false
```

Re-enable it with `true` or delete the override. Remember that the shared defaults domain means the setting affects other SideScreen variants that use the same bundle identifier.

The legacy SHA-based `FrameSkipper` is intentionally kept out of the default adaptive path. It may be used only for controlled fixed-FPS experiments.

Cached-frame keepalives are also disabled by default. The dedicated control
channel owns liveness, and the reconnect/keyframe path explicitly replays the
cached frame when a client needs it. This keeps a static desktop at zero
keepalive encodes and video bytes after the last useful frame.

## Validation order before merge

Hosted GitHub Actions are intentionally not the acceptance gate for SideScreen. Validate the installed/runtime boundary:

1. Run macOS tests locally from `MacHost` (`swift test`).
2. Run Android unit tests and a real Android build.
3. Run relevant shell/diff checks, including the benchmark sampler below.
4. Launch the exact intended SideScreen binary by full path and verify its PID/runtime identity.
5. Run live Mac <-> Android quality, cadence, latency, and CPU checks.

A source-only build/test pass is not enough for this display pipeline.

## Hardware performance gate before merge

Run the same resolution, codec, bitrate/quality, transport, tablet build, and installed host binary for both the canonical branch and the adaptive branch. Warm each case before sampling.

| Scenario | Expected adaptive tier | SideScreen CPU | WindowServer CPU | Encode/send FPS | Visual notes |
|---|---:|---:|---:|---:|---|
| Static terminal, no input | 8 | | | | |
| Terminal typing | 60 while typing, decay after | | | | |
| Static document + caret blink | 8-15 | | | | |
| Web scrolling / drag | 60-120 | | | | |
| 30-FPS video | <=60 | | | | |
| 60-FPS YouTube | 60 after probe | | | | |
| High-cadence animation / cursor-circle test | up to session ceiling | | | | |

For each row, sample the same duration on both branches. Prefer an explicit PID so multiple SideScreen variants cannot contaminate the measurement:

```bash
SIDESCREEN_PID=<pid> ./scripts/benchmark-adaptive-refresh.sh static-terminal 30 results/static-terminal.csv
```

The CSV records branch/commit/macOS/hardware plus one-second SideScreen and WindowServer CPU samples. Also retain SideScreen logs containing `Adaptive refresh:` so the measured CPU can be tied to the actual tier selected by the governor.

For a capture-source comparison on the live virtual display, use the exact
installed bundle and the display ID printed by the host:

```bash
./scripts/run-capture-source-benchmark.sh <display-id> 10
```

The results are appended to `/tmp/sidescreen.log` as
`capture-source-benchmark:` entries. This diagnostic was structured around
the same capture-cadence question documented by the MIT-licensed
[Telemachus](https://github.com/aaditagrawal/telemachus) reference project;
SideScreen does not copy its implementation or add a legacy CG fallback.

A CPU/power win does **not** justify visible latency, dropped interaction, decoder instability, degraded image quality, or a regression below stable 60 FPS where motion actually needs it. A smoothness win does **not** justify pinning an unchanged desktop at 120 FPS.

## Virtual-display refresh follows the validated capture ceiling

The virtual display is configured once at session start with the same effective
ceiling used by ScreenCaptureKit and VideoToolbox. This avoids asking
WindowServer for a 120 Hz source while the selected Main10 path is capped at
60 FPS. Adaptive content changes still update ScreenCaptureKit's capture
cadence; they do not repeatedly switch Core Graphics display modes.

## Regression rules for future changes

Any change to cadence thresholds, ScreenCaptureKit configuration, frame skipping, encoder scheduling, display modes, or input handling must:

1. Preserve the session/wireless caps and Android decoder limits.
2. Add or update deterministic policy tests.
3. Re-run the hardware matrix above when the change can affect capture cadence or latency.
4. Keep an A/B path until the hardware result is recorded.
5. Never claim a performance improvement from frame skipping alone if ScreenCaptureKit is still capturing at the old high cadence.
6. Never claim "120 FPS" from a configured ceiling alone; record actual encoded/received cadence during the live test.
