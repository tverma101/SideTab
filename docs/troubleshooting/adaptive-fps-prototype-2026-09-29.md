# Adaptive frame rate — prototype results

## Status

Prototyped and simulated. **Not implemented.** Branch `codex/rename-sidestab`
is unchanged.

## Model validation

The prior pass's headline numbers reproduce:

| anchor | prior | this model |
|---|---|---|
| fixed-60 bitrate, 180 s script | 2.91 Mbps | 2.938 |
| fixed-60 avg frame age | 16.64 ms | 16.44 |
| cadence sweep 60/30/20/12 fps | 12.45/6.22/4.15/2.49 | exact (analytic) |
| saturating controller | 39.97 flat | 40.00 flat |

The cadence sweep and the saturating result are **not fits** — they fall out of
the model structure. The 12.45 Mbps figure implies a single per-frame size of
25,938 B, and the power law through the two measured anchors reaches that at
m=0.481. The saturating result required fixing the rate limiter: a hard 1-second
window cap is not a sustained rate; it must be a token bucket refilling at
`AverageBitRate/8` with 1.5 s capacity.

**What was fitted, and should be distrusted:** the 180 s *script* (segment
durations) was fitted so the aggregate lands on 2.91 Mbps, because the original
script was not in the repo. So "2.91 reproduced" means *a* plausible mixed
session reproduces it, not *the* session. Frame age was fitted as a 2-parameter
lognormal, of which 7.14 ms is unattributed queue-hop residual, not measured.

## The finding that changes the design

**The area thresholds are nearly irrelevant to safety. The translating-damage
test is the whole safety story.**

Sweeping A_LO and A_HI ±2× in both directions across all content classes:
0.8–14.2% bitrate reduction, **100% retention of every perceptually-critical
class, everywhere**. Too low just under-decimates. Too high over-triggers into
FULL, which costs bandwidth but never correctness.

Turning off the *translating-damage* test drops cursor retention to **55.8%**.
That is the only change in the whole parameter space that can hurt a user.

The reason: inside the class of content that must stay at 60 fps there is a
**five-order-of-magnitude spread in dirty area**:

| class | dirty-area fraction | must be 60 fps? |
|---|---|---|
| cursor move | **0.00042** | yes — a viewer always sees it |
| in-place spinner | 0.00012 | no |
| caret blink | 0.011 | no |
| typing | 0.030 | yes |
| video-call tile | 0.036 | yes |
| window drag | 0.210 | yes |
| scroll | 0.430 | yes |
| video 1080p | 0.480 | yes |

Cursor (0.00042) and video-call (0.036) differ by **86×** yet both need 60 fps.
No pair of area thresholds can separate them. A displacement test can, because
in-place content (spinner, caret) has **exactly zero** displacement while any
motion has non-zero.

Recommended: `A_LO = 0.02`, `A_HI = 0.30`, **`moveCentroidPx = 0.5`**. The
0.5 px figure is not arbitrary — a sweep showed 4 px fails any pointer creeping
1–3 px/frame (56% retention) while 0.5 px holds **100% at every speed from 1 to
20 px/frame**, and costs nothing on in-place content.

**Drop the `rectCount/512` correction term.** Every class has an expected count
of 1–6 (macOS damage is per window layer: a caret is one quad, a browser scroll
is 3–6). The term is a no-op on real content and a liability, because it
multiplies magnitude by N/8 and can push a genuinely small change over A_HI.

## The dirty latch — the rule the prior pass lacked

Once a change frame is gated, **every later change frame submits until one goes
out.** Without it, typing retention was 87.8% because a 10 key/s run is 2–3
*consecutive* change frames: onset submits frame 1 and drops 2–3, leaving the
tablet a keystroke stale.

With the latch, content staleness is **provably bounded at 1 frame (16.7 ms)**
in every scenario, because two change frames can never be gated consecutively.

Note the correct verdict metric is `maxGatedRun` (staleness), not encode count.
Decimation is the point; stale content is the defect.

## Controller specification

**Escalate to FULL — one frame, zero dwell** if any of:
- magnitude ≥ A_HI (0.30) — area
- duty ≥ 0.35 over a 30-frame/500 ms window — sustained activity
- damage-rect origin displaced ≥ 0.5 px from the previous frame — translating
- `pendingEncodeSkips` incremented — encoder saturation
- the frame is an onset (change frame following an idle frame)

**De-escalate** one step only, on sustained low duty (< 0.50): FULL→MID at
2.0 s, MID→LOW at 6.0 s. Use duty, not a quiet-period dwell — a 1.06 Hz caret
never produces a 2 s quiet period, so quiet-period dwell leaves the stream at
60 fps forever on exactly the class where decimation is free. Escalation
restarts the duty window **empty**.

**GOP rule.** All three VT properties are overdetermined by one number, since
`gopFrames = frameRate * 5` makes the duration 5.0 s at every rate:

```swift
let gop = Double(frameRate) * 5.0
set(ExpectedFrameRate, frameRate)
set(MaxKeyFrameInterval, Int(gop))
set(MaxKeyFrameIntervalDuration, gop / Double(frameRate))  // == 5.0 exactly
```

Write all three from one variable in `makeConfiguredSession()`. An
inconsistent triple silently moves the Android 6 s stale-keyframe watchdog's
margin.

**Thermal never caps FULL — proof by construction.** The escalation predicates
read only magnitude, duty, displacement and `pendingEncodeSkips`. None reads
`thermalState`. The cap applies only to the rate returned for frames that did
*not* escalate, so it cannot lengthen the path to a full-rate submit. Measured
recovery: **16.13 ms at all four thermal levels, identical**. `thermalState` is
confirmed unused anywhere in `MacHost/Sources`.

**The client cannot drive this.** `WireMessage` occupies 0–15 with no gaps;
there is no free tag, and a byte-at-a-time skipper would desync. Independently
the client has nothing to ask for: the measured client is not starved, and a
client request arrives over the wire — slower than the host's own signal, which
is already in hand at submit time.

## Adversarial results

| scenario | encodes reduced | FULL% | missed events | noticed? |
|---|---|---|---|---|
| alternating static↔scroll | 0.0% | 100% | 0 | no |
| slow fade over static | 0.0% | 37% | 0 | no — area fails **safe** (m=1.0) |
| video call, small tile | 0.0% | 100% | 0 | no — duty holds 60 |
| **cursor-only animation** | **0.0%** | **100%** | 0 | **no — 100% of encodes kept** |
| static page + scrolling feed | 0.0% | 100% | 0 | no |
| spinner only | 45.2% | 3.3% | 0 | no — the win |

The small-but-critical case is exactly where area-gating alone would have been
wrong, and the move test is the mitigation.

## Recovery latency

| stage | worst | mean |
|---|---|---|
| wait for next 60 Hz tick | 16.67 ms | 8.33 |
| `SCFrameStatus` read | 0.0004 ms | — |
| bounded K=8 probe | 0.0049 ms | — |
| decision + lock | 0.0002 ms | — |
| VT submit return | 0.50 ms | — |
| **to submit** | **17.17 ms** | **8.84** |

- fixed-60: **17.17 ms** — adaptive: **17.17 ms, identical**
- fixed-30: 33.84 ms

The controller adds **0.000 ms**, because escalation is evaluated *on* the
escalating frame with no dwell. A fixed rate has no recovery *event*; it is
already at full rate and pays the full tick wait every time.

## Rollout

1. **Dry-run first, no gating.** `SideScreen_exp_adaptiveGate = 1` computes and
   logs every decision but submits everything. Log magnitude, rect count, duty,
   displacement, chosen state, and what *would* have been gated. Run a week —
   this is the only way to get the measured dirty-area distribution we lack.
2. **Watchlist.** `maxGatedRun` must never exceed 1; per-class encode counts;
   alert if any class with `m < A_HI` drops below 95% retention.
3. **Enable gating** behind the same default, **MID-only first** (30 fps floor,
   no LOW). LOW adds the most savings and the most risk.
4. **Auto-fallback to fixed-60** on `maxGatedRun > 1`, a `pendingEncodeSkips`
   burst, elevated encode-error rate, or rising client stale drops. Fall back
   by pinning state, never by rebuilding the session.
5. `UserDefaults` overrides for `A_LO`, `A_HI`, `moveCentroidPx` so a bad
   threshold is fixable without a rebuild.

**Zero-regression property:** the controller only decides which already-complete
frames get submitted. It never calls `restartStream()` (2.6–13 s), never
rebuilds the encoder, never changes the capture cadence. A fallback to
fixed-60 is a single state assignment.

## What would falsify this

1. **A real capture showing cursor displacement below 0.5 px/frame** for a
   normal mouse sweep. The entire safety story rests on this one assumption; at
   4 px the sweep measured 56% retention for 1–3 px/frame creep.
2. The onset/latch model being wrong about ScreenCaptureKit — if a keystroke
   produces bursts longer than modelled, staleness could exceed one frame.
3. Retaining 60 fps for cursor + video-call costing more than it saves. The
   model shows only ~11% encodes / 1.6% bitrate on a mixed session. If real
   sessions have far less idle time, the honest conclusion is that this is an
   encoder/CPU optimization, not a bandwidth one.
4. `.idle` meaning something other than "display did not change."

## Three bugs the simulation caught in itself

Worth recording because all three are the kind that ship:

1. The duty ring shifted **twice per tick**, destroying the signal.
2. Escalation re-baselined duty to 0.50 — above the 0.35 enter threshold —
   creating a feedback loop that pinned the controller at 100% FULL forever.
3. The pointer model clamped-and-flipped its step sign, so 834 of 1093 frames
   reported zero displacement and a "moving" cursor looked stationary. Only
   found by adding a per-class trigger counter.
