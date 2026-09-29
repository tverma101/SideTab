# Performance measurement and the lower-level-language question

## Scope

Whether rewriting SideTab in a lower-level language (Rust, C++, C) would
produce meaningful efficiency gains, and what evidence exists either way.

Reviewed: the host's per-frame path end to end, the Android client's per-frame
and per-input paths, the optimisation work already in the repository, and the
comparable lower-level projects. This record exists so the question does not
have to be re-litigated without data.

## Verdict

**Do not rewrite.** The per-frame cost is not in this codebase's language.

## Where the time actually goes

One 60 Hz frame, host to tablet:

| Stage | Where the work happens | Managed code's share |
|---|---|---|
| Capture | `SCStream` (ScreenCaptureKit) + WindowServer | one attachment read |
| Colour convert | none — SCK delivers YUV 4:2:0 | 0 |
| Encode | `VTCompressionSessionEncodeFrame`, hardware media engine | 4 locks + 1 `CMTime` |
| Annex-B framing | Swift `memcpy` over NAL units | **the one real managed cost** |
| Send | `NWConnection` → kernel TCP | a 5-byte header append |
| Decode | `MediaCodec`, hardware | one `ByteBuffer.put` |
| Display | `Surface` / SurfaceFlinger | 0 |

Two independent measurements bound the Swift-versus-Rust delta:

- `screencapturekit` (Rust, 2.2M downloads) reports its own binding overhead as
  **below the noise floor of a 4 kHz sampling profiler**, with full capture at
  ~1.9% of one core.
- `mac-screen-cast` (Rust: SCK → VideoToolbox → RTP) runs the whole host
  pipeline at **~3% of one core**.

So the upper bound on what a rewrite could recover is a fraction of ~3% of one
core, because the remaining ~97% is ScreenCaptureKit's out-of-process pipeline,
the hardware media engine, and kernel TCP.

## Why a rewrite could not reach most of the pipeline anyway

Of 14 critical platform dependencies, 9 are effectively locked to Swift/ObjC
or Kotlin/Java:

| API | Rust/C++ reachable? |
|---|---|
| `SCStream`, `SCStreamConfiguration` | via `objc2` FFI only; no headers exist |
| `CGVirtualDisplay` (private) | **no binding exists at all** |
| `NWConnection` | `objc2-network` is a reserved 0.0.0 stub; uses OS objects, not ObjC |
| `MediaCodec`, `MediaCodec.Callback` | JNI/NDK only; needs Java-side marshalling |
| `MotionEvent`, `Choreographer`, ADB | no |
| `VTCompressionSession*` | **yes** — plain C API |
| CoreMedia, vImage | **yes** — already C and already SIMD |

The three that are callable from C are precisely the ones already at the C
boundary and already doing the expensive work. The codebase already contains a
hand-written ObjC shim plus a module map for `CGVirtualDisplay` — a full
rewrite would extend that pattern to everything, turning ~11,900 lines of Swift
into FFI declarations plus the same logic.

On Android the addressable fraction is effectively 0%: `MediaCodec` is
hardware, and the client already uses the async `MediaCodec.Callback` pattern on
a `THREAD_PRIORITY_DISPLAY` HandlerThread. JNI marshalling would cost more than
the Kotlin it replaced.

## The code is already optimal where it counts

- Hardware encoder explicitly requested (`VideoEncoder.swift`).
- IOSurface-backed pixel buffers, no CPU readback.
- 420YpCbCr capture — encoder-native, so no CPU colour conversion.
- HDR tone-map via Accelerate `vImageLookupTable_Planar8toPlanar16` (SIMD), not
  a Swift loop.
- Async `MediaCodec.Callback` on a display-priority thread.
- Allocation-free input coalescer; ~3 allocations per frame on the host.
- Both GPU renderers (`CflRenderer`, `SgsrRenderer`) are shaders, off by default.
- `DitherPass` (the only per-pixel Swift loop) and `HDRConverter` are **off by
  default**, so the shipping path contains zero Swift per-pixel work.

## Prior experiments already settled this

Two CPU-side optimisations were tried, measured, and **reverted as net
losses** (`backups/2026-08-15-sharpness-investigation-paused.md`):

- Host vImage luma sharpening before VideoToolbox: the added high-frequency
  content made the stream harder to encode and decode, causing keyframe and
  drop cascades. The source file was deleted.
- Android post-decode CPU/GPU sharpening: 30% gave no visible gain, 60% made it
  feel more laggy. Both removed.

A third, `FrameSkipper`, hashes the entire Y and CbCr planes per frame on the
capture thread to save 1.6–5.3 Mbps of mostly-local traffic. Its own notes
record that measurement and leave it off, because `CaptureDirtyRectGate` gets
the same benefit from ScreenCaptureKit's metadata at zero per-pixel cost.

## Comparable lower-level projects are worse, not better

| Project | Host language | Outcome on macOS |
|---|---|---|
| scrcpy | C + Java | **Architecturally inverted** — mirrors Android to a host, not macOS to Android. No macOS capture path. Host decode is software-only. |
| Sunshine | C++ | macOS port does not build on modern Xcode; had an all-keyframe bug (3x bandwidth). |
| Lumen (Sunshine fork) | C++/ObjC | Had to move `CGVirtualDisplay` to a separate subprocess. |
| RustDesk | Rust | Does not use ScreenCaptureKit on macOS; hardware HEVC broken (`-12900`), silently falls back to software. |

scrcpy deserves a specific note because "just adopt scrcpy" is tempting: it
encodes on the *device* and decodes on the *host*, which is the mirror image of
this architecture. It has no macOS capture, no virtual display, no S Pen, and
its control model is HID rather than `MotionEvent`. Adopting it would cost the
entire feature set and increase CPU.

## What would actually be needed to prove this empirically

The honest blocker was never the analysis, it was that the repository had no
per-stage instrumentation — a repo-wide search for `os_signpost`, `xctrace`,
`Instruments`, allocation counters and benchmarks returned nothing. The only
performance number was a single end-to-end "frame age".

**That gap is now closed.** `FramePipelineSignpost` instruments the five stages
a rewrite would have to target, including the Annex-B output callback which is
the only one carrying real managed byte work. Cost when no trace is recording:
0.368 µs per interval pair, 1.84 µs per frame, 0.011% of a 16.7 ms budget.

```bash
xcrun xctrace record --template 'Time Profiler' \
  --launch -- /Applications/SideTab.app/Contents/MacOS/SideScreen
```

The prediction is a nearly-flat managed-code profile dominated by framework
block time. That is a prediction, and this instrumentation exists so it can be
checked rather than assumed.

## Lower-risk alternatives, by payoff per effort

1. **Measure first** (0.5 day). The trace above. Decides the question
   empirically.
2. **Re-test the 10-bit profile** (hours). Measured at ~6.4–7.5 Mbps versus
   ~10 Mbps for 8-bit at the same fps and latency — a bandwidth and
   encode-pressure win. Currently gated behind experimental defaults.
3. **Metal compute shader for the HDR path** (3–5 days), *only if* HDR ships.
   This is the one place a lower-level tool is genuinely justified, and it is
   Metal, not a language change. Zero payoff on the default SDR path.
4. **Lift the USB telemetry guards** (hours). The capture-cadence and
   encoder-cadence counters are wireless-only, so if USB is the shipping
   default, the primary transport is the least observable one.
5. **A SwiftPM C target for one isolated hot function** (2–3 days), if the
   question must be closed by measurement rather than argument. This buys a
   real A/B on the language delta for ~1% of the cost of a rewrite.

Not worth doing: a full rewrite, on any language.

## Revalidation triggers

Revisit only if a trace shows managed code dominating the profile — which would
contradict everything above and mean the bottleneck changed. Also revisit if
ScreenCaptureKit or VideoToolbox gain an off-process or non-Swift-native path
that materially changes the binding cost, or if the app stops using hardware
encode, which would move real work back onto the CPU.
