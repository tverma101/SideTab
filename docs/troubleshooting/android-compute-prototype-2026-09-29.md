# Android client compute — prototype results and corrections

## Status

Prototypes and patches built and measured in scratch. **No repo file changed, no
APK built or installed, no device touched.** Branch `codex/rename-sidestab` is
unchanged.

## Validation basis

| What | How | Status |
|---|---|---|
| Android unit tests | full scratch copy, real AGP 8.4.0 / Kotlin 1.9.22, `--offline` | 77 tests 0 failures at baseline; **110 tests 0 failures** with all 6 patches |
| `lintDebug` (the CI gate) | same | **0 errors** |
| Bytecode claims | `javap -c` | verified |
| Allocation sizes | `ThreadMXBean.getThreadAllocatedBytes`, escape analysis off | measured on **HotSpot**, not ART |
| A3 estimator | discrete-event sim, 6 traces × 4 policies | model, not device |
| MediaCodec / CPU / thermal / OEM surface callbacks | — | **cannot be validated here** |

Object *counts* are architecture-independent. Object *sizes* are HotSpot; ART's
8-byte header makes each object 4 B smaller.

## Corrections to the previous pass

1. **A7's quoted KDoc does not exist on this branch.** `git log --all -S"over
   budget always means drop"` finds nothing reachable — that text was
   *introduced by* `c1c286e`, which is not an ancestor of `codex/rename-sidestab`.
2. **A7 is worse than stated and affects both transports.** `VideoDecoder.kt:595`
   reads `if (wireless && hasValidLatency)`, so a **wireless** session with an
   uninterpretable (>2 s) age also falls to the `else` and renders. The prior
   pass attributed it to USB only.
3. **A1 is 5× worse than "~260 objects/s"**: measured **164.5 B/frame =
   9.87 KB/s = 34.7 MB/h and ~304 objects/s**. The once-per-60-frames emit
   costs 8,456 B and ~244 objects; the per-frame box is only 24 B of the 164.5.
4. **A4 needs no Java file.** A Kotlin `fun interface` with primitive params
   compiles to `invokeinterface …([BIJZ)V` with zero `valueOf` calls. Verified
   by `javap`.
5. **A2's `limitedParallelism(1).threadFactory{}` option does not compile** and
   is backed by the same pool thread anyway, so it cannot raise priority.
6. **A3's premise does not survive contact with the code** — see below.

## Ranked verdicts

| # | item | measured benefit | verdict |
|---|---|---|---|
| 1 | **A6** release the pipeline on `onStop` + quiet-frame guard + TextureView backstop | up to 300 s × 0.5–0.6 core, **and** 2 forced IDRs/s × 2×5 MB of wasted link | **ship code / needs-device number** |
| 2 | **A5** zero-allocation `InputPredictor` | **10,560 B/s → 0**, 240 obj/s → 0, 37 MB/h → 0 | **SHIP** |
| 3 | **A7** freshness decision + tests | correctness of the stalest-frame path on **both** transports; 7 tests | **SHIP** (cherry-pick, fix the USB hole) |
| 4 | **A1** gate + primitive frame-timing window | **9,871 B/s → 0**, ~304 obj/s → 0, 34.7 MB/h → 0 | **SHIP** |
| 5 | **A2** dedicated `VideoReadThread` @ −4 | real, bounded by ~6–18% of one core | **needs device** |
| 6 | **A4** `fun interface` primitive sink | 2,401 B/s → 0, 120 obj/s → 0 (6% of volume) | **SHIP, lowest** |
| 7 | **A3** adaptive input-buffer wait | **zero, and negative on 1 of 6 traces** | **REJECT** |
| 8 | novel client adaptations | n/a | **REJECT** (one alternative flagged) |

## A3 — rejected, and the reason is structural

A wait that *succeeds* ends when the codec hands the buffer back, **not** when
the budget expires. The budget is a pure deadline. Shortening it cannot make an
accepted frame cheaper — it can only convert an accepted frame into a timeout,
and a timeout drops the frame, sets `needsKeyframe` (short-circuiting every
following P-frame before it reaches the codec) and requests a **forced** IDR.

Simulated across 6 traces. The cost of a bad budget:

| trace | policy | timeouts | forced IDRs | IDR bytes |
|---|---|---|---|---|
| measured baseline | fixed 25 ms | 0 | 0 | 0 |
| slow degradation 8→80 ms | adaptive | 0 | 0 | 0 |
| **one 40 ms outlier** | fixed 1 ms | 28 | 6 | **30 MB** |
| **sustained saturation** | fixed 25 ms | 2 | 2 | 10 MB |
| | **adaptive** | **3** | **3** | **15 MB** |
| | fixed 1 ms | 280 | 71 | **355 MB** |

A forced IDR at 2800×1752 is 5 MB = **1,049 ms of the entire 40 Mbps budget**.
The client force gate is 200 ms (≤5/s) and **the host's 500 ms throttle is
bypassed when `force = true`**, so a saturated client can demand 25 MB/s on a
4.8 MB/s link. On the sustained trace the estimator made things *worse* (2 → 3
timeouts).

Two further findings the previous pass missed:

- `inputBufferWaitTimeouts` increments only on the real timeout path, and
  `needsKeyframe` short-circuits every following P-frame *before*
  `pollInputBuffer`. So timeouts are at most **~1 per keyframe cycle** — far too
  sparse to drive a controller.
- **The `outputFrameCount % 60` block that resets those counters is only
  reachable on the rendered SurfaceView path.** Both the `!shouldRender` early
  return and the `bufferOutput` (CfL) early return bypass it. **On a CfL session
  the counters are never reset**, so today's `inputWait avg=…` line is a
  lifetime average. That is a live reporting bug independent of A3.

The decisive measurement already exists: the baseline reports *"input-buffer
waits ≈ 0, zero timeouts"*. `inputBufferWaitCount == 0` means the wait is never
entered, so the budget is **not binding** and no adaptation can change anything.

**Better adjacent fix:** bound the force-request rate by *progress* rather than
time. One outstanding forced request, escalate only if no IDR arrives within N
ms. Caps the storm at 1 instead of 5.

## A6 — the highest-impact item, and the trap inside it

`onStop` is the correct hook, not `onPause`: a visible-but-unfocused Activity in
split-screen is STARTED, not STOPPED, so `onStop` leaves a working stream
alone. PiP is unreachable (no `supportsPictureInPicture` in the manifest).

**The rebuild path is safe.** `onStart` → `surfaceView.post { … }` runs on the
main looper; the view hierarchy stays attached across `onStop`. If the surface
is gone, `activeVideoSurface()` returns null, the function logs and returns, and
`surfaceChanged` fires and retries anyway.

**The trap — this is the important part.** Releasing the decoder makes
`videoDecoder` null, so `deliverFrame` takes its not-ready path for every
subsequent frame. That path is not background-safe today:

```kotlin
client.releaseBuffer(frameData)
if (displayWidth > 0 && displayHeight > 0) {
    client.requestKeyframe(reason = "decoder not ready")   // 2/s, non-force
}
mainDiag("FRAME DROPPED: decoder not ready; …")            // 60/s
```

Each keyframe request reaches the host's `requestKeyframeOrReplayCachedFrame`,
which re-encodes and sends `cachedPixelBuffer()`. **Two full-resolution 5 MB
frames every 500 ms = up to 20 MB/s demanded on a 5 MB/s link, for up to
300 s.** Plus 60 `mainDiag` lines/s into `diag.log`, which rotates at 1 MB ≈
every 2.3 minutes — destroying exactly the history you would want.

**Without a `videoPipelineSuspended` early return, this fix would make
backgrounding far worse than the 0.5 core it removes.** That guard is
non-negotiable. `publishVideoPipeline` already requests a forced keyframe on
rebuild, so nothing is lost.

Also fix the TextureView branch: `onSurfaceTextureDestroyed` fires on view
*detach*, not on `onStop`, so a flipped display has **no** teardown at all.
Gate on "a pipeline exists" rather than on `decoderUsingTextureView`.

## A5 — zero-allocation InputPredictor

Measured 88 B/sample → 0 B/sample (240 obj/s → 0, 37 MB/h → 0).

Recommended form is **two out-fields**, not packing and not a shared holder:
packing costs two `floatToRawIntBits` round-trips and an unreadable call site;
a shared holder creates an aliasing hazard across a second call. The compiler
enforced the change — `val (px, py) = …predictPosition(12f)` fails to compile,
so the API break is impossible to miss.

The rewrite is bit-identical over 500 samples. Nine new tests pin the exact
prior behaviour, including a 240-sample 120 Hz stroke checked against
hand-recomputed linear extrapolation.

`getCurrentVelocity()` returns a `Pair` and **has no caller anywhere** — decide
whether to keep it.

## A2 — read-loop priority

`Dispatchers.IO` has **no other video-path user** on this branch:
`ControlChannel` runs on its own raw thread at `MAX_PRIORITY`, its
`tcpReadLoop` sets `THREAD_PRIORITY_DISPLAY` itself, and `startPingTimer`'s
coroutine spends its life in `delay()`. The previous pass's claim that
ControlChannel connect and ping loops share the pool is inaccurate here.

Cancellation is unchanged: the loop has never been cancellable by suspension — it
blocks in `input.readByte()` and relies on `cleanupTransport()` closing the
socket.

Cap at `-4`, equal to `DecoderThread`, **not higher**: going above the decoder
would let the producer starve its own consumer. Flagged risk: the elevated read
loop takes four monitors, one of which the UI thread also takes, so there is a
narrow (microsecond) priority-inversion surface. And the ceiling on the win is
small — the read loop's CPU is parse + memcpy + `queueInputBuffer`, estimated
1–3 ms per 16.7 ms frame.

## Novel adaptations — all rejected

**Forced IDR on sustained `staleOutputDrops`.** The diagnosis was right, the
remedy wrong. An IDR resets the **reorder** buffer, not the **output** buffer —
and this app configures `max-b-frames = 0` and `low-latency = 1`, so it is
*asked* to have no reorder buffer. Frames already decoded and sitting in the
output queue are already in presentation order; an IDR does not touch them. And
the dominant cause is transport: a 5 MB IDR takes ~1 s to cross a 40 Mbps link,
so asking for more bytes worsens the congestion that created the staleness.

**Relaxing the 33.33 ms gate when behind.** It is a *drop* mechanism and dropping
is the only thing that reduces the queue. Relaxing it converts a bounded-latency
system into an unbounded one, and removes the signal the host's own backpressure
decisions depend on. The one case where it looks defensible — a static desktop
under the dirty-rect gate — is exactly the case with no backlog, so it would be
a no-op anyway.

**Proactive IDR on rising `inputWait`.** Confirmed reject, quantified: up to
355 MB of forced IDRs in simulation, and the causal chain is inverted —
`inputWait` rising means the decoder is behind, and the proposed remedy hands it
the most expensive frame in the stream. A positive feedback loop into the exact
pathology it claims to fix.

**Flagged, not proposed:** the right shape for a real client→host adaptation is
re-advertising `MESSAGE_CLIENT_DECODER_LIMITS` (tag 15), which the host treats
as authoritative — `encodeSize` says so verbatim. It costs an encoder rebuild on
the host and a decoder rebuild on the client, so it needs device validation of
the host's re-plan latency. Larger change than this pass should absorb.

## Needs a real device

- **A6's headline number.** Whether `surfaceDestroyed` fires on background on
  this OEM. The TextureView leak and the keyframe storm are real either way.
- **A2's benefit.** Requires a CPU-saturation scenario; there is nothing to
  measure in the healthy case.
- **A6's `MediaCodec.stop()` cost on the main thread**, and rebuild latency on a
  quick background/foreground cycle.
- **A5's predicted behaviour** — the maths is identical but prediction error is
  perceptual, not algebraic.
- Nothing for A1, A3, A4, A7.
