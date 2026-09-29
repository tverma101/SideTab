# Session lifecycle — random Android disconnects and a Mac that never timed out

## Scope

Two reports that looked like one bug and were not:

1. The Android tablet dropped its display "randomly" while the Mac was
   demonstrably still streaming.
2. Mac streaming never timed out after being disconnected for five minutes.

Both are session-lifecycle defects, but on opposite sides of the wire and with
opposite root causes: the client retired live transports on *absence of
evidence*, and the host never ended a session on *absence of evidence* at all.

## Symptom 1 — random disconnects

The tablet's display would go dark / report disconnected at unpredictable
moments during a working stream. The Mac kept encoding and kept its own UI
state. No network change, no user action, and no error correlated with it.

## Root cause 1

`StreamClient.sendPing()` retired the video transport on a **6-second
read-loop timer** whose entire evidence base was "did the read loop produce
anything" (`VIDEO_PROBE_TIMEOUT_NS = 6_000_000_000`, introduced by `1f29543`
"watchdog and recover frozen video TCP path").

Silence is not death, for three independent reasons:

- The Mac deliberately sends **no frames** for an unchanged desktop
  (ScreenCaptureKit clean-frame suppression, see `docs/wireless-60fps.md`).
  Silence is the normal state of a healthy, idle stream.
- The read loop is **not isolated from the decoder**. It calls
  `onFrameReceived` inline, which reaches `MediaCodec.getInputBuffer` and
  `queueInputBuffer`, so decoder backpressure, GC, or thermal throttling stalls
  it for seconds.
- A **pong is queued behind video data** on the host, so an actively
  delivering stream can miss its own probe deadline.

What made it fire *randomly* rather than only on an idle desktop was
`ControlChannel.PONG_TIMEOUT_NS = 4_000_000_000L`. A control socket sharing a
congested Wi-Fi link with video loses three consecutive 1 Hz pongs to a
momentary stall routinely, and the client then closed a healthy control socket.
Worse, the resulting `sendPing() == false` short-circuited the video probe's
"is video flowing?" guard:

```kotlin
(!controlSent || (!videoRecentlyActive && now - lastVideoProbeSentNs >= ...))
```

so **any** control hiccup armed the video probe at 1 Hz regardless of whether
video was flowing. Control-channel health was silently controlling
video-channel retirement.

Contributing, in rough order of severity:

| # | Defect | Site |
|---|---|---|
| 1 | Silence-based retirement, 6s, no corroboration | `StreamClient.sendPing` |
| 2 | 4s control-pong false-fire, and it armed the video probe | `ControlChannel.sendPing` |
| 3 | Any in-band **write** failure tore down the session with no read-side health check | `StreamClient` |
| 4 | Reconnect budget (1s/2s) shorter than the host's 5s contender window | `connectWireless` |
| 5 | Byte-exact parser reported a framing desync as a transport failure | `receiveData` |
| 6 | `configChanges` omitted `density`/`uiMode`/`colorMode`/etc., so a dark-mode or HDR toggle recreated the Activity and `onDestroy` tore the session down | `AndroidManifest.xml` |
| 7 | Wireless freshness bypassed for output older than 2s — the stalest frames were the only ones guaranteed to render | `VideoDecoder` |

Items 3 and 4 are why a single false positive became a **~58-second visible
outage**: 8 reconnect attempts across up to 3 host candidates, with the UI
still reporting "Connected" the whole time.

## Symptom 2 — the Mac never timed out

**The five-minute timeout did not exist anywhere in the host.**
`rg "300" MacHost/Sources/StreamingServer.swift` returned zero hits. The only
`300` in the product was Android-side, for a *backgrounded* session.

The host could only learn a client was gone through the video socket's
`.failed`/`.cancelled` state handler. It could not otherwise, because:

- The receive loop **swallowed** a clean EOF and a reset error entirely
  (`isComplete` is the normal signal for a peer that closed).
- All four control-channel terminal exits just nil'd the socket.
- **TCP keepalive was never enabled** on either socket.
- A peer whose Wi-Fi association drops sends no FIN and no RST, so the socket
  stays `ESTABLISHED` on both ends indefinitely.

The consequence compounded: a stale `settings.clientConnected == true` made
`IdleSleepMonitor` clear `idleSince` on every tick (so capture never paused),
made `refreshStatusIndicators` early-return, and made the USB checklist
never re-probe. One stale flag silently disabled every periodic host check,
and the Paired Devices row and menu bar kept rendering a green "Connected".

Note the time base. `DispatchTime.uptimeNanoseconds` maps to
`mach_absolute_time`, which **stops advancing across system sleep**, so a
five-minute deadline implemented on it would not elapse overnight — precisely
the "disconnected and forgotten" case.

## Implemented changes

### Host

- `SessionLifetimePolicy` (new, pure): owns the deadline as a `Duration`
  decision, so it is testable without a socket and can use `ContinuousClock` —
  monotonic *and* sleep-inclusive.
- A repeating `DispatchSourceTimer` watchdog on `networkQueue`, armed on first
  publish only (a later capability re-advertisement cannot hand the client a
  fresh budget) and fenced by a session generation so a tick queued before a
  reconnect cannot act on the client that replaced it.
- Silence measured from bytes the **client** sent, on either socket. The frame
  sender emits a keepalive encode on a fixed cadence regardless of whether the
  peer is reading, so a send-side clock is reset forever by writes queued into
  a dead socket.
- Receive-loop EOF/error routed through `markDisconnected()`.
- Control-channel exits routed through `markControlDisconnected()`, which ends
  the session only when video is not live either.
- TCP keepalive enabled on both sockets as a kernel-level floor.
- Timeout escalates through a separate `onSessionTimeout` hook so the host can
  stop the server and release the virtual display, which an *observed* socket
  error deliberately does not do (the tablet is allowed to reconnect on its
  own). This asymmetry is intentional.

### Client

- `VideoLivenessPolicy` (new, pure): retirement now requires a dead read path
  **and** two consecutive unanswered probes **and** an elapsed budget. An
  active read path outranks every timer.
- Liveness tracked on **any** inbound byte, not just video frames —
  display-config re-sends, codec selection and stylus advertisements are all
  proof of life.
- Control-channel health removed from the video arming decision entirely.
- Control pong budget 4s → 15s, armed only after the write returns (the packet
  still carries the pre-write timestamp so RTT includes our own drain time).
- A probe write blocking past 10s is transport evidence in its own right.
- Every in-band write failure routed through `failVideoTransportIfReadPathDead`.
- First reconnect after a live session budgeted at 8s/8s to exceed the host's
  5s `authenticatedContenderWindow`; later attempts stay short on purpose, to
  fail over to the next host candidate quickly.
- Stream desync given its own error type and recovery arm.
- `configChanges` completed.
- Wireless freshness decision lifted into
  `WirelessFreshnessPolicy.shouldRenderOutput` so the caller's contract is
  testable (it was previously inline in a `MediaCodec` callback, which is why
  the policy's own tests could not see the bug).

## Validation

- `swift test --package-path MacHost`: 236 tests, 0 failures.
- `./gradlew :app:testDebugUnitTest`: 93 tests, 0 failures.
- `./gradlew :app:lintDebug`: 0 errors (12 pre-existing warnings, unrelated).
- Re-validation against project memory: the 6s timer and the 4s pong were both
  introduced deliberately (`1f29543`, `b86dfb4`). Both changes refine the
  original intent — a genuinely frozen transport *is* still detected — rather
  than reverting it.

## Residual gaps and revalidation triggers

- **No live-device proof yet.** Both suites are unit-level. The random
  disconnect was intermittent by nature, so a green run proves the false
  positive is gone, not that the user-visible symptom is fixed. Revalidate on a
  real tablet over Wi-Fi, ideally with a 30+ minute session, which is roughly
  when the old 6s timer would have fired repeatedly.
- The host watchdog is a 5s tick; a session can therefore end up to ~5s late.
  Acceptable, but do not shorten `watchdogTick` much further without measuring.
- `MAX_WIRELESS_RECONNECT_ATTEMPTS` is still 8. With the patient first attempt
  the worst-case recovery window is now minutes rather than ~58s, which is
  correct for a real blip but a long time to look stuck. If users report the
  reconnect state hanging, that count is the dial — not the first attempt's
  budget, which must stay above the host's contender window.
- The `archive/sidescreen-fork/*` branches hold a released 0.11.3 and a
  Windows/Linux host port that diverged from `origin/main` at `a651a81`. That
  fork also contains `fix(mac): make server startup lifecycle reliable`
  (`9a2afdf`), which touches `StreamingServer` and may interact with the
  watchdog added here. **Not yet reviewed or merged** — revalidate the watchdog
  against it if that work is taken up.
- `docs/troubleshooting/` was gitignored until this record, so the two earlier
  records were local-only and are now tracked for the first time. A fresh clone
  still has no history predating 2026-09-11.
