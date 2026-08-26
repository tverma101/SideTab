# Wireless 60 FPS freshness experiment

Tracks: #7, #21, #27, #34

## Goal

Make ordinary Wi-Fi behave like a low-latency second-display transport at a hard 60 FPS ceiling while preserving the corrected 8-bit/video-range wired quality baseline.

This experiment is freshness-first. It must not obtain smoother motion by accumulating old frames.

## What Apple/Sunshine/Moonlight teach us

Apple Sidecar can use a proprietary low-latency wireless link layer for real-time Continuity traffic. SideScreen on Android uses ordinary Wi-Fi, so link-layer behavior cannot simply be copied.

Mature game-streaming clients use two ideas that are applicable here:

1. keep decoded presentation history tiny (Moonlight Balanced uses only one extra frame of jitter headroom); and
2. on lossy datagram transports, packetize below MTU and use explicit loss recovery/FEC rather than trusting a large socket buffer.

The second item is NOT a reason to rewrite SideScreen to UDP before measuring the current TCP path.

## Current SideScreen baseline

- Wireless capture/display cap: 60 FPS.
- Wireless average encoder target: 40 Mbps.
- Existing video transport: TCP with TCP_NODELAY.
- Existing Android video receive buffer request: 1 MiB.
- Existing Mac sender gate: generic 3 frames / 8 MiB.
- Existing Android stale decoder-output gate: 100 ms.
- Dedicated TCP control channel is separate from bulk video.
- Protocol/security hardening remains owned by #34/#8/#12/#13.

## Experimental freshness policy

The branch introduces a shared policy, not yet a production claim:

```text
target FPS                         60
frame interval                     ~16.67 ms
Mac max sender in-flight frames    2
Mac sender byte headroom           6 MiB
Android max decoded age            ~33.33 ms (2 frame intervals)
optional paced extra frame         1 maximum
```

Why 2 sender frames instead of 1 initially:
- one frame currently draining + one following frame permits useful network/encoder overlap;
- it bounds frame-count history more tightly than the generic 3-frame window;
- large IDR/access-unit behavior still has byte headroom while #14/#7 measure actual emitted sizes.

Why ~33 ms decoded age:
- 100 ms is roughly six 60-Hz intervals and is too stale for a second monitor;
- two intervals gives startup/jitter headroom without accepting a visible historical drain;
- the immediate mode remains the baseline; the first frame is exempt for startup recovery.

## Integration order

### Phase W1 — current TCP, tighter sender freshness

Wire `WirelessSessionProfile.senderLimits` into the `StreamingServer` instance only for `.wireless` sessions.

Requirements:
- USB retains `FrameBackpressureLimits.default` until separately measured;
- `canAdmitNextFrame()` must see the same wireless limits before VideoToolbox submission;
- an overload must skip work before encode where possible;
- if encoded dependency state becomes invalid, enter the existing sync-frame gate and recover with a new IDR;
- log in-flight frames/bytes and send-completion latency.

### Phase W2 — Android stale-output gate

Use `WirelessFreshnessPolicy.MAX_DECODED_FRAME_AGE_NS` only for wireless decoders.

Requirements:
- USB keeps its existing behavior for the A/B baseline;
- first/startup frame may render even if old;
- stale decoder outputs are discarded, not displayed to drain history;
- stale P-frame output drops must NOT be confused with dropping encoded input references.

### Phase W3 — receiver pacing A/B (#21)

Compare:

A. `immediate`: release fresh decoded output immediately; no intentional presentation buffer.

B. `balanced-1`: Choreographer/vsync-paced output with at most one extra decoded frame. When a newer decoded frame supersedes one that has not been presented, prefer freshness according to the codec dependency/output-surface constraints.

Hard rule: no mode may queue more than one extra presentation frame. There is no "smoothest / never drop" mode for SideScreen.

### Phase W4 — bitrate/quality sweep

At native 2800x1752, corrected 420v HEVC baseline:

```text
12 Mbps
20 Mbps
30 Mbps
40 Mbps
```

For each run collect #16 quality metrics plus #27 cadence/latency. The winning wireless bitrate is the lowest value that does not produce a meaningful visible/objective regression on desktop UI and motion.

Do not use the old accidental USB 1000-Mbps behavior as a quality target.

## Runtime matrix

Target hardware:
- Mac: current SideScreen target Mac
- Android: Samsung SM-X800 / Tab S8+
- output: native 2800x1752
- wireless stream cap: 60 FPS

Network states:
1. strong 5/6-GHz LAN, same room;
2. normal household contention;
3. induced 5/10/20/40 ms jitter;
4. short 50/100/250 ms transport stall;
5. bandwidth restriction around 15/25/40/60 Mbps where practical;
6. temporary packet loss if the test harness can induce it reproducibly.

Content:
1. static UI -> immediate scroll;
2. typing/caret;
3. constant-velocity motion corpus;
4. text/page scroll;
5. 30 FPS video;
6. 60 FPS video;
7. high-complexity full-screen motion;
8. large keyframe recovery after induced stall.

## Required per-frame evidence

Mac:
- frame id;
- capture timestamp;
- encode admitted/completed;
- encoded bytes;
- sender in-flight frames/bytes;
- send enqueue/completion;
- send completion latency;
- pre-encode/admission/sync drops.

Android:
- frame header parsed / full frame received where practical;
- receive inter-frame interval;
- translated capture -> receive;
- receive -> decoder input;
- decoder input -> output;
- output age at release/drop;
- Surface render timestamp;
- stale-output drops;
- rendered frame interval.

## 60 FPS acceptance shape

Do not accept average FPS alone.

The candidate should demonstrate:
- steady rendered FPS close to 60 on the target network;
- no monotonically growing sender/decoder/presentation queue;
- no duplicate/reordered frame IDs;
- p50 inter-render close to one 60-Hz interval;
- p95/p99 cadence tails explicitly reported;
- after a short stall, convergence to current desktop pixels without draining a long old queue;
- control/touch RTT remains independent from video pressure;
- corrected wired-quality baseline is not materially regressed at the selected bitrate.

Numeric p95/p99 pass thresholds should be chosen from the first native-Android + current-wireless baseline rather than invented before the measurement.

## TCP vs UDP/FEC decision gate

Do NOT migrate just because game streaming uses UDP.

Keep TCP if, after W1-W4:
- sender completion remains bounded;
- capture -> receive p95/p99 is within the display latency budget;
- induced ordinary Wi-Fi loss does not cause visible multi-frame head-of-line stalls;
- recovery reaches fresh pixels quickly;
- 60-FPS cadence is close to native Android.

Open/implement a Protocol-V2 datagram video transport only if traces show TCP head-of-line blocking remains the dominant wireless tail after sender/receiver queueing is bounded.

If a datagram path is justified, evaluate:
- separate reliable/session-bound control path;
- frame + fragment sequence IDs;
- ~1200-1400-byte payload target or path-MTU-derived value;
- late-fragment/frame abandonment;
- bounded FEC (start A/B around 10-20%, never assume 20% is optimal);
- keyframe recovery after unrecoverable frame loss;
- authenticated encryption/session binding under #34/#12;
- no unbounded reassembly buffer.

Do not add new V1 one-byte message hacks for this transport.

## Status

This branch currently defines and unit-tests the cross-platform freshness policy. Live-path wiring and target-hardware receipts are required before any policy value is called production-ready.
