# Transmission and compute deep dive — findings and proposals

## Scope

Deep investigation of the actual transmission path: wire bytes, pixel formats,
frame rate, and compute cost on both sides. Five specialist passes: adaptive
frame rate, wire/bitstream accounting, capture/pixel pipeline, Android client
compute, and novel-technique research.

Everything below is either measured, computed from measured figures, or
explicitly labelled an estimate. Assumptions are separated from results.

## TL;DR

**Ship now (safe, measured, cheap):**

| # | Change | Benefit | Confidence |
|---|---|---|---|
| A1 | Delete dead `trackFrameTiming` stats | 260 obj/s, only per-frame alloc in the output path | **High** |
| A2 | Elevate the video read loop to `THREAD_PRIORITY_DISPLAY` | removes scheduler lag + telemetry degradation | **High** |
| A3 | Adaptive `INPUT_BUFFER_WAIT_MS` (from already-measured wait time) | up to 24 ms off every saturation stall | **High** |
| A6 | `onStop` must stop the decoder | up to 300 s of invisible 0.5–0.6 core + 375 MB | **High** |
| A7 | Fix the `WirelessFreshnessPolicy` USB/KDoc contradiction | correctness | **High** |
| A8 | Replace the first-frame `String.format` dump | removes a per-connect cold-start hitch | **High** |
| C4 | AVC `ConstrainedBaseline` → `Main` | −4.6% bytes fixed-bitrate, −10% quality-matched | Medium-high |
| C3 | Signal AVC colour description | correctness (decoder no longer guesses) | High |
| C4b | Fix portrait-AVC aspect error (1.06% > 1.00% tolerance) | correctness | High |
| H1 | `CaptureDirtyRectGate` early-exit decode | 660 ns/rect → 0.9 µs constant; removes a 14.6%-of-budget worst case | **High** |
| W2 | Bound USB `AverageBitRate` (currently 1000 Mbps) | restores rate control that does not exist | High |

**Measure first, then decide:**

| # | Change | Why measure first |
|---|---|---|
| C1 | `PrioritizeEncodingSpeedOverQuality=false` | **−24% to −32% bytes at equal quality** — but encode latency 7.4 → 12.1 ms median (44% → **72%** of a frame budget). May trigger transport skips that cost more than it saves. USB-only, HEVC-only, gated. |
| W1 | Promote 10-bit Main10 SDR to default | two measurements disagree by an order of magnitude (see below) |
| A3b | Adaptive FPS controller | −37% encodes, −18% bitrate, **zero** latency cost in simulation — but thresholds are uncalibrated |

**Rejected — do not revisit (all measured, not guessed):**

| Idea | Why it fails |
|---|---|
| ROI / importance-map encoding | **No VideoToolbox API exists.** Complete frame-scoped set is 4 keys. `BaseFrameQP` disables rate control. `EnableUserQPMap` is undocumented with no public map-supply path. |
| Downscale during quiet periods | Measured: the codec's contribution to loss is **0.0021**; the resample already destroyed **0.0208**. The codec is 9% of the problem. Also Lanczos-on-text *raises* source entropy by up to 46% — the exact mechanism that got vImage sharpening rejected. |
| 1400×875@120 vs 2800×1752@60 | Same resample floor; halves pointer density (a 1px hairline renders 2px wide, unfixable). Worse on every axis for a pointer-accurate display. |
| Lossless / screen-content modes | No VT API. `Quality=1.0` disables rate control (73.6 Mbps measured against a 45 limit). |
| Shorter GOP to cut latency | The 160 ms per-IDR link spike is **independent of GOP length**; only its frequency changes. 2 s would spend 18.7–22.2% of the stream on IDRs for zero latency benefit. |
| Single-window capture | Breaks the pointer-accurate input model; same SCStream cost; fails on occlusion/Spaces. |
| Drop `BufferedInputStream` | TCP is a byte stream; the kernel does not deliver frame-sized chunks. Zero bytes saved. |
| NAL start-code shrinking, `SO_SNDBUF` | <0.12% of a frame. No value. |
| Decouple read loop from decoder | **The 25 ms stall is the load-shedding mechanism.** A handoff queue converts a bounded observable stall into unbounded invisible latency. |
| Enabling CfL/SGSR by default | 18% of frame budget; failure mode is a mid-session full pipeline restart on exactly the hardware least able to absorb it. |

## Bytes on the wire

14-byte header (1 type + 4 size + 1 flags + 8 timestamp), 4-byte size field in
both the metadata and legacy paths. NAL start codes: 4 B/frame.

At 10 Mbps / 60 fps / 2800×1752 (20,833 B/frame):

| component | bytes | % |
|---|---|---|
| protocol header | 14.00 | 0.067% |
| NAL start codes | 4.00 | 0.019% |
| parameter sets (amortised) | 2.52 | 0.012% |
| **payload** | **20,812.82** | **99.902%** |

**The protocol costs 0.0985% of a frame. There is nothing to win in the
framing.**

**Static pixels are not redundant bits.** 2800×1752 is 1,232 CTUs. A fully
static CTU costs ~1 `cu_skip_flag` bit, so a 95%-static frame spends ~146 B of
20,833 B — **0.70%**. The encoder is already at the information-theoretic floor
for unchanged content. Any "send only what changed" scheme has a ceiling
**under 1%** for frames actually being sent. MediaCodec has no partial-refresh
API at all.

Transport: 15 packets/frame over 1500 MTU = 8.0% IPv4+TCP overhead, which exists
regardless of this codebase. USB loopback (64k MTU) = 0%.

## 8-bit vs 10-bit — an unresolved disagreement

| Source | Measurement |
|---|---|
| Repo (`backups/2026-08-16-60fps-stability-fixes.md`) | 10-bit **6.4–7.5 Mbps** vs 8-bit ~10 Mbps at identical fps/latency — **30% win** |
| Pixel swarm, equal-quality ladder | 10-bit only **−0.6%** |

These cannot both be right. Either SideTab's real content is much harder than
synthetic (plausible — subpixel-antialiased text, gradients, video), or the
earlier comparison was at **fixed bitrate** rather than fixed quality. Only a
real capture distinguishes them. **Do not promote 10-bit before that.**

If it is adopted, prerequisites: 10-bit is unreachable by a normal user today
(it needs two undocumented `defaults write` keys), SCK delivers 10-bit directly
so no CPU conversion is needed, and `noteColorimetryMismatch` currently fires
a **false** "ScreenCapture fell back" log on **every frame** of the exact
configuration being promoted — it compares depth, not profile.

## Adaptive frame rate — the strongest proposal

**Decimate the ENCODE path, never the change detector.**

`minimumFrameInterval` stays put. SCK keeps delivering at display rate; the
controller decides only whether an already-changed frame is *submitted*.

This is forced by two measured facts:
- The only existing rate-change path is `restartStream()`, measured at
  **2.6–13 s**.
- Decimating capture instead would put the inter-frame gap directly on
  motion-onset latency (83 ms at 12 fps).

**Bandwidth follows from gating frames out, not from changing the rate.** With
`ExpectedFrameRate` pinned at 60, submit cadence alone moved 12.45 → 6.22 →
4.15 → 2.49 Mbps at 60/30/20/12 fps with **byte-identical per-frame size and
zero keyframes**.

Corollary that inverts the usual assumption: under a *saturating* rate
controller, a lower fps buys **zero** bandwidth (measured 39.97 Mbps at 30/60/
90/120 fps) — it only buys lower encoder/decode/transport load and lower power.

**Actions on transition:** three `VTSessionSetProperty` calls
(`ExpectedFrameRate`, `MaxKeyFrameInterval`, `MaxKeyFrameIntervalDuration`),
all measured to return 0 on a live session, **none of which forces a keyframe**
(0 keyframes across 80 frames after a 60→15 change). Nothing else — no
`negotiate()`, no `rebuildEncoder()`, no `updateSettings()`, no
`restartStream()`. All three must move together, or the GOP silently stretches
from 5 s to 20 s.

**Simulation, 180 s mixed session:**

| metric | fixed 60 (shipped) | adaptive | Δ |
|---|---|---|---|
| average fps | 27.53 | 17.34 | −37% |
| average Mbps | 2.91 | 2.38 | **−18.1%** |
| frame age, scrolling | 19.51 ms | 19.51 ms | **+0.00** |
| frame age, video | 21.99 ms | 21.99 ms | **+0.00** |
| worst recovery latency | 0.0 ms | 0.0 ms | **+0.0** |
| encodes | 4,955 | 3,121 | −37% |
| frames client would discard | 34 | 34 | 0 |

The +2.29 ms on *average* frame age is entirely IDR amortisation on quiet
content — under every class where something visibly moves, the two are
bit-identical.

**The blocker is calibration, not design.** `A_HI`/`A_LO` and the `rectCount`
normaliser are inferred from bytes/frame bands, not from a measured dirty-area
distribution. Ship H1 (the gate rewrite) first with a logged histogram, then
tune. Two safeguards: a self-calibrating escape using the previous frame's
encoded byte count (`sendEncodedFrame` already has `data.count`), and treating
unparseable metadata as **full rate**, never as "no change".

**Do not let a future contributor "optimise" this** by lowering
`minimumFrameInterval` when quiet. It is available (`SCStream.updateConfiguration`,
macOS 12.3+), looks strictly better, and costs the 2.6–13 s restart plus 83 ms
of motion-onset latency. Put the reason in the code with a test.

## Encoder headroom

| Comparison, bytes at equal quality | vs VT default |
|---|---|
| VT + `PrioritizeEncodingSpeedOverQuality=false` | **−24% to −32%** |
| x265 scc-tuned (`preset slow`, rd=6, no-sao, no-deblock) | −46% to −61% |

So the hardware encoder leaves ~1.5–1.9× on the table. **~25–32 points are
recoverable inside VideoToolbox with one public property**; the rest requires
abandoning hardware encode, which costs ~100–200× the whole pipeline's CPU —
already established as non-viable.

The latency is why `PrioritizeEncodingSpeedOverQuality` is not free: 7.37 →
12.06 ms median (44% → 72% of a 16.67 ms budget), and **14.65 ms (88%)** on
Main10. Gate to USB + HEVC + non-Main10, and watch the existing
`WirelessTransportPressure` skip counters.

Also: the hardware encoder's own `SpatialAdaptiveQPLevel` is already doing
useful work on this content (turning it **off** costs both quality and bytes),
and there is no client-side dial to shape it.

## Colour correctness

- **HEVC 8-bit SDR is correct.** Range is signed `tv`, and HEVC's inferred
  BT.709 default for an unspecified matrix is spec-correct. Verified by dumping
  the SPS VUI and reading it with ffprobe.
- **The AVC path is not.** VideoToolbox writes *neither* the range flag nor a
  colour description for AVC, so the client is guessing (and guessing right, by
  luck). Fix by signalling the AVC VUI.
- A wrong signalled matrix costs **zero** bits — the encoder's RDO never reads
  its own VUI. The real bitrate risk is on the **capture** side, where a
  mismatched matrix changes the pixel values the encoder must code. That is the
  same mechanism that killed the rejected sharpening experiment.
- `preservesAspectRatio` defaults to true and is never set; with
  `scalesToFit=false` the AVC path fits 1738.8×1088 inside a 1744×1088 buffer.

## Resolution / scaling

There is **no scaling** on the HEVC-no-client-limit path: the encode resolution
*is* the capture resolution (1:1). Scaling enters only via `encodeScale`, a
client decoder limit, or the AVC floor.

Two real findings:
- **2800×1752 is not 16-aligned** (1752 % 16 = 8). Legal, but HEVC CTU is
  64×64, so 44×28 = 5,046,272 coded pixels against 4,905,600 useful —
  **2.87% extra coded area**.
- **Portrait AVC produces a 1.06% aspect error**, exceeding the repo's own
  1.00% test tolerance. The clamp's documented 0.68% bound is stated for the
  landscape case only. Reachable on a Boox Nova Air C.

The **AVC clamp is the real AVC problem**, not the profile: 2800×1752 →
1744×1088 discards 61.3% of the pixels, which dwarfs a 10% CABAC saving.

## Android compute

Bytecode-derived, not estimated.

**Allocations: ~750–860 objects/s, 33–42 KB/s, 120–150 MB/h.** This cannot
cause GC pauses in the measured 8.4–9.9 ms window — at 42 KB/s a young-gen
collection is ~13 minutes away. **Do not optimise this.** The likely cause of
the ≤23.7 ms tail is a single 25 ms `INPUT_BUFFER_WAIT_MS` timeout, which the
existing 1 Hz diag string already prints.

**A1 is the exception — 100% waste.** `trackFrameTiming` boxes a `Long` per
frame and allocates ~260 objects/s to compute an FPS and a standard deviation
for `onFrameStats`/`onFrameRendered`, **neither of which is assigned anywhere in
the app**. Verified by grep across main and test.

**The read loop runs at nice 0.** Every other streaming thread is elevated
(`DecoderThread` −4, `TouchThread` −4, control threads −20). The read loop does
~100% of per-frame parsing *plus* the inline decode submit, and it is the thread
that increments every adaptive-telemetry counter — so on a contended device the
telemetry degrades exactly when it matters. ~15 lines to fix.

**The 25 ms `getInputBuffer` stall is a feature, not a bug.** The async
callback hands out dequeued indices, so it is not a blocking call. The stall is
the client's only load-shedding mechanism. Make it *cheaper* (A3) rather than
*absent*.

**Decoder is not stopped on background.** No `onPause`/`onResume`/`onTrimMemory`
exists. Teardown rides entirely on `surfaceDestroyed` — and the TextureView
branch is a **no-op by construction**, so that path never tears down. Worst
case: 300 s of invisible 0.50–0.59 core plus 375 MB received.

**Memory is a non-issue.** Java heap live set ≤6 MB against 192–256 MB. The real
pressure is native (MediaCodec input buffers, glalloc output `GraphicBuffer`s).
`maxInputSizeBytes`'s 5 MiB clamp exactly equals the host's own `MAX_FRAME_SIZE`
and is bit-depth-independent by construction. `isLowRamDevice` is the wrong
instrument — `MESSAGE_CLIENT_DECODER_LIMITS` from real `VideoCapabilities` is
strictly stronger.

**CHANGELOG inaccuracy:** 1.1.0 and 1.0.0 both claim "Choreographer vsync
alignment", removed in `c724230` (v0.3.0) as a stutter fix. `rg Choreographer`
returns zero. Vsync pacing now happens implicitly via BufferQueue backpressure.
Historically true, but it misleads anyone auditing today.

## Highest-risk finding: IDR under a congested link

A measured IDR is **297,398 B — 12.1× a median P-frame**. At 15 Mbps that is
**160 ms of link serialization, ~10× a frame interval**, and it is the direct
cause of the 181 ms worst-case frame age in every simulation row.

`maxSenderInFlightBytes = 6 MiB` is **3.2 s of link time** at 15 Mbps, and
`observeSendBuffer` explicitly *discards* `frameBytes`. The guard is sized for a
22 kB frame and is **off by 13×** for an IDR.

Mitigation, in order of value:
1. Make the in-flight byte budget **IDR-aware** — the `frameBytes` parameter
   already exists and is already ignored. Cannot reduce the IDR's own
   serialization (TCP must push the bytes) but stops the following frames
   queueing behind it.
2. Reduce absolute IDR size (10-bit Main10 is the right lever, if the
   disagreement above resolves in its favour).
3. **Do not** shorten the GOP.

## Needs a live measurement or bitstream capture

1. **The 10-bit disagreement** — the single highest-value capture. Sniffer is
   already written and syntax-verified; `ffprobe` confirms profile/pix_fmt and
   gives the real IDR-to-P ratio.
2. `.idle` fraction by content class (counters exist, wireless-only, never
   captured).
3. Real dirty-area distribution → `A_HI`/`A_LO` calibration.
4. The `FramePipelineSignpost` trace — closes the host latency split.
5. Whether `surfaceDestroyed` reliably fires on background across Samsung/BOOX.
6. Real IDR size on real content (297,398 B is synthetic, ~1.47× too hard).
7. `availableSendBuffer` behaviour on the E3/VPN path (documented as unreliable).

## Note on cross-machine numbers

Two harnesses measured an **85–87 fps** encoder ceiling while the repo records a
**110.2 fps** direct-path baseline. These are close enough that they should be
treated as **different machines** until proven otherwise. `A_HI` calibration is
correspondingly machine-specific.
