# Adaptive USB FPS

Branch/PR experiment for high-refresh wired SideScreen sessions.

## Goal

Keep the capture source hot at up to 120 Hz for immediate interaction response, while adapting the expensive encode/send/decode cadence to actual content and sender pressure.

## Static-content policy

ScreenCaptureKit dirty-rect metadata is used before VideoToolbox:

- active content: motion controller target
- 150 ms clean: cap at 60 FPS
- 600 ms clean: cap at 30 FPS
- 2 s clean: cap at 15 FPS
- first changed frame after idle: always send immediately
- missing/unrecognized dirty metadata: fail open at the configured maximum
- synthetic pattern/dither passes: bypass the dirty gate
- forced keyframe/recovery request: bypass the gate

No per-frame full-buffer hashing is required.

## Motion-load policy

For configured rates above 60 FPS, USB motion uses a 60/90/max ladder. A 120-Hz stream therefore adapts 120 -> 90 -> 60 and cautiously climbs 60 -> 90 -> 120.

Primary pressure evidence:

1. Network.framework sends overlapping before `.contentProcessed`.
2. `.contentProcessed` taking multiple target-frame intervals.

Corroborating evidence:

- TCP send-buffer headroom becoming critically small (<32 KiB).

A large encoded frame being larger than the currently available TCP send buffer is **not** treated as congestion. Network.framework can consume a larger application send asynchronously; completion/backlog is the stronger signal.

### Hysteresis

- 3+ sends in flight: severe pressure, one-step downshift (subject to 250 ms adjustment cooldown).
- 2 sends in flight: mild pressure; two mild strikes required.
- critically low TCP headroom: mild pressure only.
- healthy send completion can decay a mild strike.
- 60 -> 90: requires 12 healthy completions and at least 2 s pressure-free.
- 90 -> max: requires 12 healthy completions and at least 5 s pressure-free.
- failed upward probe within 2 s adds a ramp penalty; future recovery delay doubles per penalty up to 3 penalties.
- long stable operation at the ceiling gradually forgives penalties.
- source maximum changes mid-session reset the learned ladder while preserving the transport.
- stale callbacks from an older connection generation are ignored.

## 90 FPS pacing from a 120-Hz source

The pacer carries an ideal send deadline forward rather than checking only elapsed time since the last sent frame. This avoids quantizing an 11.1 ms target interval onto 8.33 ms source samples as ~60 FPS. Deterministic tests require 90 FPS to pass 9 of 12 120-Hz source frames.

## Android display policy

SideScreen expresses a 120-FPS display intent when MainActivity starts and requests minimal post-processing on Android 11+.

- Android 14 / API 34 and newer: request 120 Hz directly. Android allows `preferredRefreshRate` to be an intended rate even when it is not an exact advertised panel mode, then chooses the compatible display refresh itself.
- Android 13 / API 33 and older: `preferredRefreshRate` must be an advertised mode, so SideScreen chooses the same-resolution rate closest to 120 Hz. Equal-distance ties prefer the higher refresh rate so presentation is not unnecessarily capped below the stream rate.

Examples covered by JVM tests:

- 60/90/120/144 -> 120
- 60/90/144 -> 144
- 60/96/144 -> 144 (96 and 144 are equally distant from 120; higher wins)
- 60/90 -> 90
- 59.94/119.88/144 -> 119.88

This is only an OS preference; thermal, power, user, and device policy may override it.

## Intentionally not included yet

- Dynamic SCStream reconfiguration. Capture stays at the configured maximum to avoid configuration-transition latency.
- Treating every keyframe request as decoder overload. Startup, reconnect, resolution changes, and real decoder pressure share the same request path, so the signal is ambiguous.
- VideoToolbox `MaximumRealTimeFrameRate`. It is a good semantic match for variable-rate real-time input, but current platform availability is newer than SideScreen's macOS 13 deployment floor; keep `ExpectedFrameRate` for this branch until deployment/SDK behavior is proven.
- Automatic resolution/bitrate adaptation. FPS is isolated first so a hardware trace can identify the actual bottleneck later.

## Hardware-free validation

Swift tests cover static ramp-down, forced recovery, fail-open behavior, 120/90/60 cadence, pressure hysteresis, recovery backoff, stale generations, mid-session maximum changes, and a longer marginal-path simulation.

Android JVM tests cover version-aware refresh-rate selection. CI also builds the macOS arm64/x86_64 release binaries and Android application.

Hardware validation is still required before merging to claim sustained real-device 120 FPS or to tune thresholds for a specific tablet/USB path.
