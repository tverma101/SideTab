# Adaptive USB FPS

Branch/PR experiment for high-refresh wired SideTab sessions.

## Integration notes (2026-09-29)

This work was written against an older `main` and merged onto the SideTab consolidation stack, which had independently changed three of the areas it touches. Where the two disagreed, the stack's behaviour was kept and this design was fitted around it:

- **Clean frames.** The stack's `CaptureDirtyRectGate` (formerly `WirelessDirtyRectGate`) already drops every frame ScreenCaptureKit reports as unchanged, on *both* transports, and the frame sender has its own keepalive. So the static-content tiers below (60/30/1 FPS) and the 1 FPS deep-idle keepalive are not in effect. `USBAdaptiveFramePacer` runs *after* that gate on USB and only paces changed frames through the motion ladder. The wake-from-idle punch-through still works, because the pacer measures idle time from changed frames only.
- **Android refresh rate.** `PowerPolicy` owns the panel request, because it is newer and power-aware: 120 Hz only on external power, 60 Hz on battery, seamless 60 Hz on wireless, cleared when idle. `SideScreenApplication`, which asked for 120 Hz unconditionally, was removed so the two would not fight over the same surface. `DisplayRefreshPolicy.chooseLegacyPreferredRate` now snaps the power policy's window request to an advertised mode below API 34, and `preferMinimalPostProcessing` is set by `MainActivity`.
- **Decoder.** The stack's hardened `VideoDecoder` and cached `CodecCapabilities` inventory were kept. This branch's 120-FPS provisioning (USB only; wireless stays 60), the operating-rate-without-low-latency configure attempt, and the performance-point ranking were ported onto them.

## Goal

Keep the capture source hot at up to 120 Hz for immediate interaction response, while adapting the expensive encode/send/decode cadence to actual content, host encode pressure, sender pressure, downstream recovery behavior, and the Android decoder's published capabilities.

## Static-content policy

> Superseded on integration by the stack's all-transport dirty-rect gate; see the notes at the top.

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

The Android video-path liveness probe does not begin until a 3-second frame-silent interval, so a 1-FPS keepalive remains comfortably inside the existing liveness model.

## Motion-load policy

For configured rates above 60 FPS, USB motion uses a 60/90/max ladder. A 120-Hz stream therefore adapts 120 -> 90 -> 60 and cautiously climbs 60 -> 90 -> 120.

Primary pressure evidence:

1. Network.framework sends overlapping before `.contentProcessed`.
2. `.contentProcessed` taking multiple target-frame intervals.
3. VideoToolbox holding a queue of about six frames (submit -> output callback) for 250 ms.
4. Repeated decoder recovery/keyframe pulses from the client-facing recovery path.

Corroborating evidence:

- A TCP send-queue backlog of more than 64 KiB beyond the frame about to be sent.

`NWProtocolTCP.Metadata.availableSendBuffer` is the number of bytes still queued in the kernel send buffer, not free space. It reads 0 on the idle ADB loopback socket. Until 2026-10-06 it was read as headroom: every frame looked like "critically low headroom" pressure, which reset the healthy-completion count, so the ladder dropped at connect and never climbed back. The queue is sampled before the current frame is submitted, so a big frame still draining from the previous send is allowed for.

### Host encode feedback

The encoder records when each frame is handed to VideoToolbox (a 16-entry ring keyed by presentation timestamp, no per-frame allocation). The output callback uses that to measure the encoder's own time. The age from capture is used only when no submit time is found, because it also carries ScreenCaptureKit delivery delay. That delay spiked to 50–60 ms with the encoder at 9 ms, and dropping frames after capture cannot relieve it.

- threshold: max(25 ms, six target-frame intervals): 50 ms at 120 FPS, ~66.7 ms at 90, 100 ms at 60
- every encoded frame must stay over it for 250 ms before a downshift
- an under-budget frame ends the streak
- the forced-IDR grace window suppresses encode pressure from a large recovery keyframe

The threshold is a queue, not a per-frame budget. When big motion starts after a still screen, VideoToolbox's rate control overshoots: 165–330 Mbps for about 2 s against the 112 Mbps cap. During that burst the encoder time plateaus at 37–43 ms and the output still reaches ~96 FPS. The plateau is flat, so the encoder is pipelining, not falling behind, and it was just as slow at 60 FPS. The earlier rule (three intervals, two frames) turned every motion start into seconds at 60/90. An encoder that really cannot keep up builds a queue whose latency only grows, so it crosses six intervals and stays there.

This catches the case where VideoToolbox is slipping even though the USB/TCP sender and Android decoder still look healthy.

### Startup grace

For 3 s after a USB connection starts, no pressure moves the ladder. Connect sends a host keyframe and the decoder's own keyframe request, and often rebuilds the encoder after codec negotiation. Its first second therefore looks like both a recovery burst and encode overload on a healthy path; this alone used to take every session 120 -> 90 -> 60 within a second of connecting.

### Diagnostics

While the controller is active it logs one summary line about every 2 s, for example:

```
USB adaptive: target=120 frames=224 encodeAge avg=4.0ms max=17.0ms vt avg=7.1ms max=11.9ms n=223 over=0 pressure: sendBacklog=0 sendBuffer=0 slowSend=0 encodeAge=0 recoveryBurst=0 ignored=0 healthy=406 penalty=0
```

`encodeAge` is capture -> encoder output, `vt` is submit -> encoder output, `over` counts frames above the encode threshold, `pressure` counts recorded samples by kind, and `ignored` counts samples dropped by the startup or forced-IDR grace.

### Decoder-recovery burst feedback

A single client keyframe request is ambiguous: decoder initialization, reconnects, resolution changes, and codec resets can all legitimately ask for one. SideScreen therefore does **not** downshift on an isolated recovery.

The Android decoder's genuine input-buffer starvation path repeatedly force-requests an IDR and already rate-limits forced requests to 200 ms. The host reuses that existing recovery path without adding a wire-protocol message:

- one or two recovery pulses inside 1 s: no FPS change
- third recovery pulse inside 1 s: severe downstream pressure, step down one motion tier
- counter resets after the downshift; another fresh burst is required for the next tier
- pulses more than 1 s apart do not accumulate
- the normal 250 ms controller adjustment cooldown still applies

This adds a downstream signal for the case where ADB/TCP itself is healthy but MediaCodec cannot sustain the supplied cadence.

### Forced-IDR pressure grace

A forced IDR is intentionally much larger than a routine P-frame. One normal startup/recovery IDR can therefore create short-lived send backlog, a deep send queue, slow `.contentProcessed`, or elevated encode time even on a healthy 120-FPS path.

Each explicit recovery pulse creates a 250 ms grace window in which transport and encode-age pressure are ignored. Repeated recovery pulses themselves are **not** ignored: a three-pulse recovery burst still steps down the FPS ladder. This separates “the recovery IDR was large” from “the steady-state path cannot sustain 120 FPS.”

### Hysteresis

- 3+ sends in flight: severe pressure, one-step downshift (subject to 250 ms adjustment cooldown).
- 2 sends in flight: mild pressure; two mild strikes required.
- send queue more than 64 KiB beyond the next frame: mild pressure only.
- encoder time above max(25 ms, six target-frame intervals) on every frame for 250 ms: severe pressure.
- any pressure in the first 3 s of a connection: ignored.
- 3 recovery pulses inside 1 s: severe downstream pressure.
- healthy send completion can decay a mild strike.
- 60 -> 90: requires 12 healthy completions and at least 2 s pressure-free.
- 90 -> max: requires 12 healthy completions and at least 5 s pressure-free.
- failed upward probe within 2 s adds a ramp penalty; future recovery delay doubles per penalty up to 3 penalties.
- long stable operation at the ceiling gradually forgives penalties.
- source maximum changes mid-session reset the learned ladder while preserving the transport.
- stale callbacks from an older connection generation are ignored.

## Capture interval

USB asks ScreenCaptureKit for twice the session rate, like Wi-Fi. SCK drops a frame that lands sooner than `minimumFrameInterval` after the one before it, so an interval equal to the display period aliases against compositor jitter: a 120 Hz session delivered ~109 FPS of steady motion, and 117–121 FPS with the 2x interval. The virtual display refresh is still the ceiling, and the pacer below still owns cadence. ScreenCaptureKit then stamps frames with the upcoming display time, so the `Pipeline` "avg frame age" diagnostic reads only a few ms on USB too; the encode signal above does not depend on it.

## 90 FPS pacing from a 120-Hz source

The pacer carries an ideal send deadline forward rather than checking only elapsed time since the last sent frame. This avoids quantizing an 11.1 ms target interval onto 8.33 ms source samples as ~60 FPS. Deterministic tests require 90 FPS to pass 9 of 12 120-Hz source frames.

## Periodic keyframe policy

A one-second USB keyframe-duration limit conflicts with 1-FPS deep idle: it can make nearly every idle keepalive an IDR. Explicit startup/recovery keyframes already cut through pacing immediately, so adaptive high-refresh USB now uses a five-second periodic safety GOP.

- wireless: 5 s (existing behavior)
- adaptive USB above 60 FPS: 5 s
- legacy/non-adaptive USB at 30/60 FPS: 1 s (unchanged)
- `SideScreen_exp_gop`: still overrides the periodic frame-count interval

This is isolated in `EncoderGOPPolicy` with deterministic tests.

## Android display policy

> Superseded on integration: see the notes at the top. The original design is kept below for reference.

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

## Android decoder policy

The decoder is provisioned for SideScreen's 120-FPS stream intent rather than the panel's refresh rate at the instant the decoder happens to be constructed. Configuration falls back in stages when a vendor codec rejects a hint:

1. low latency + priority + 120-FPS operating rate
2. priority + 120-FPS operating rate (without the low-latency key)
3. basic prioritized config without an explicit operating rate
4. minimal resolution-only config

Decoder selection no longer relies only on codec-name prefixes on modern Android:

- API 29+: use `MediaCodecInfo.isHardwareAccelerated`, `isVendor`, and `isAlias`
- API 26-28: retain the old codec-name heuristic as a compatibility fallback
- prefer hardware decoders with manufacturer performance points covering the actual stream width/height at 120 FPS
- use manufacturer achievable-frame-rate measurements as additional ranking evidence when published
- `areSizeAndRateSupported()` is only weaker standards/capability-envelope evidence, not treated as a real-time performance guarantee
- Android 11+ low-latency feature support receives an additional ranking preference
- hardware remains preferred over software because software-only codecs make no rendering-performance guarantee

If vendor performance measurements are absent, selection still falls back to size/rate capability and hardware preference rather than rejecting the decoder.

## Intentionally not included yet

- Dynamic SCStream reconfiguration. Capture stays at the configured maximum to avoid configuration-transition latency.
- Treating every isolated keyframe request as decoder overload. Only a short recovery burst is used as pressure evidence because startup/reconnect/reset requests remain valid single events.
- VideoToolbox `MaximumRealTimeFrameRate`. It is a good semantic match for variable-rate real-time input, but current platform availability is newer than SideScreen's macOS 13 deployment floor; keep `ExpectedFrameRate` for this branch until deployment/SDK behavior is proven.
- Automatic resolution/bitrate adaptation. FPS is isolated first so a hardware trace can identify the actual bottleneck later.

## Hardware-free validation

Swift tests cover static ramp-down, one-FPS deep idle, forced recovery, forced-IDR pressure grace, host encode-age pressure, recovery-burst feedback, fail-open behavior, 120/90/60 cadence, transport hysteresis, recovery backoff, stale generations, mid-session maximum changes, adaptive GOP policy, and a longer marginal-path simulation.

Android JVM tests cover version-aware refresh-rate selection. CI also builds the macOS arm64/x86_64 release binaries and Android application, which verifies the Android Surface frame-rate and codec-capability API use against the configured min/compile SDKs.

## Live validation — 2026-10-06

Galaxy Tab S8+ (SM-X800) over USB at native 2800x1752, 120 Hz, 75 Mbps average. A test window scrolls text with GPU layers driven at 240 Hz, so the source is not the limit (CPU-drawn text tops out near 75 FPS).

| Build | Motion FPS | Ladder |
|---|---|---|
| Before | ~59 | 120 -> 90 -> 60 at connect, never climbed back |
| Queue-depth fix only | 67.6 | climbs back; every motion start dropped to 60/90 for 5–7 s |
| Encode queue rule | 109 steady | held 120 through three motion starts |
| Plus 2x capture interval | 117.6 steady (119–121 peaks) | held 120; first big motion of a session steps to 90 for ~5 s |

Encoder time at 120 FPS averaged ~7 ms. Android decode averaged 13.3 ms, with one stale-frame drop in about 50 s of motion. Bitrate settled at 71–80 Mbps. The first heavy motion after connecting still queues VideoToolbox to ~93 ms for about 250 ms. The controller steps to 90 there, and it is back at 120 about 5 s later.
