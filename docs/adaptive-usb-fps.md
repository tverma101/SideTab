# Adaptive USB FPS

Branch/PR experiment for high-refresh wired SideScreen sessions.

## Goal

Keep the capture source hot at up to 120 Hz for immediate interaction response, while adapting the expensive encode/send/decode cadence to actual content, sender pressure, and downstream recovery behavior.

## Static-content policy

ScreenCaptureKit dirty-rect metadata is used before VideoToolbox:

- active content: motion controller target
- 150 ms clean: cap at 60 FPS
- 600 ms clean: cap at 30 FPS
- 2 s clean: cap at 1 FPS keepalive
- first changed frame after idle: always send immediately
- missing/unrecognized dirty metadata: fail open at the configured maximum
- synthetic pattern/dither passes: bypass the dirty gate
- forced keyframe/recovery request: bypass the gate

No per-frame full-buffer hashing is required. The 1-FPS deep-idle keepalive avoids repeatedly waking VideoToolbox, USB/TCP, and MediaCodec for identical pixels while still providing periodic liveness/stats traffic. A dirty frame does not wait for that one-second deadline.

## Motion-load policy

For configured rates above 60 FPS, USB motion uses a 60/90/max ladder. A 120-Hz stream therefore adapts 120 -> 90 -> 60 and cautiously climbs 60 -> 90 -> 120.

Primary pressure evidence:

1. Network.framework sends overlapping before `.contentProcessed`.
2. `.contentProcessed` taking multiple target-frame intervals.
3. Repeated decoder recovery/keyframe pulses from the client-facing recovery path.

Corroborating evidence:

- TCP send-buffer headroom becoming critically small (<32 KiB).

A large encoded frame being larger than the currently available TCP send buffer is **not** treated as congestion. Network.framework can consume a larger application send asynchronously; completion/backlog is the stronger signal.

### Decoder-recovery burst feedback

A single client keyframe request is ambiguous: decoder initialization, reconnects, resolution changes, and codec resets can all legitimately ask for one. SideScreen therefore does **not** downshift on an isolated recovery.

The Android decoder's genuine input-buffer starvation path repeatedly force-requests an IDR and already rate-limits forced requests to 200 ms. The host reuses that existing recovery path without adding a wire-protocol message:

- one or two recovery pulses inside 1 s: no FPS change
- third recovery pulse inside 1 s: severe downstream pressure, step down one motion tier
- counter resets after the downshift; another fresh burst is required for the next tier
- pulses more than 1 s apart do not accumulate
- the normal 250 ms controller adjustment cooldown still applies

This adds a downstream signal for the case where ADB/TCP itself is healthy but MediaCodec cannot sustain the supplied cadence.

### Hysteresis

- 3+ sends in flight: severe pressure, one-step downshift (subject to 250 ms adjustment cooldown).
- 2 sends in flight: mild pressure; two mild strikes required.
- critically low TCP headroom: mild pressure only.
- 3 recovery pulses inside 1 s: severe downstream pressure.
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

The direct SurfaceView also uses `Surface.setFrameRate(120, FRAME_RATE_COMPATIBILITY_DEFAULT)` on Android 11+. This is Android's preferred per-surface frame-rate hint for interactive/non-fixed-rate content and lets the compositor select a compatible panel refresh. The hint is installed once per surface lifetime and reapplied only when that surface is recreated/changed, not on every adaptive FPS transition.

The window-level preference remains useful for the mirrored TextureView path and older Android versions:

- Android 14 / API 34 and newer: request 120 Hz directly. Android allows `preferredRefreshRate` to be an intended rate even when it is not an exact advertised panel mode, then chooses the compatible display refresh itself.
- Android 13 / API 33 and older: `preferredRefreshRate` must be an advertised mode, so SideScreen chooses the same-resolution rate closest to 120 Hz. Equal-distance ties prefer the higher refresh rate so presentation is not unnecessarily capped below the stream rate.

Examples covered by JVM tests:

- 60/90/120/144 -> 120
- 60/90/144 -> 144
- 60/96/144 -> 144 (96 and 144 are equally distant from 120; higher wins)
- 60/90 -> 90
- 59.94/119.88/144 -> 119.88

These are OS preferences; thermal, power, user, and device policy may override them.

## Intentionally not included yet

- Dynamic SCStream reconfiguration. Capture stays at the configured maximum to avoid configuration-transition latency.
- Treating every isolated keyframe request as decoder overload. Only a short recovery burst is used as pressure evidence because startup/reconnect/reset requests remain valid single events.
- VideoToolbox `MaximumRealTimeFrameRate`. It is a good semantic match for variable-rate real-time input, but current platform availability is newer than SideScreen's macOS 13 deployment floor; keep `ExpectedFrameRate` for this branch until deployment/SDK behavior is proven.
- Automatic resolution/bitrate adaptation. FPS is isolated first so a hardware trace can identify the actual bottleneck later.
- Replacing Android's legacy codec-name hardware heuristic. Android 10+ exposes authoritative hardware/software flags and performance points; that deserves a separate decoder-selection patch after this smaller controller/display batch is green.

## Hardware-free validation

Swift tests cover static ramp-down, one-FPS deep idle, forced recovery, recovery-burst feedback, fail-open behavior, 120/90/60 cadence, pressure hysteresis, recovery backoff, stale generations, mid-session maximum changes, and a longer marginal-path simulation.

Android JVM tests cover version-aware refresh-rate selection. CI also builds the macOS arm64/x86_64 release binaries and Android application, which verifies the Android Surface frame-rate API use against the configured min/compile SDKs.

Hardware validation is still required before merging to claim sustained real-device 120 FPS or to tune thresholds for a specific tablet/USB path.
