# SideScreen 60 FPS stability + efficiency fixes — 2026-08-16

Follow-up to `2026-08-15-sharpness-investigation-paused.md`. Goal (user):
"fix side screensharing and make it more efficient and stable at 60 FPS".

## What was actually broken (diagnosed live, 2026-08-16 evening)

1. **Probe-induced reconnect storm.** The Android checklist updater
   (`MainActivity.kt` `checklistHandler.postDelayed(..., 2000)`) probes the
   *video* port every 2 s while the app is not flagged connected
   (`checkServerRunning` connects, reads 1 byte, closes). The server was
   single-connection with cancel-on-new-arrival: every probe landing on the
   server cancelled the live video connection. The probe then closed with
   unread data → RST → "Connection reset by peer" on the Mac → app
   reconnect → probe again → 2-second reset loop (122 resets observed in one
   log). The live stream at the time rode the E3/VPN path
   (tablet → WireGuard utun10 10.77.0.2 → 10.77.0.1:54326 `ss_forwarder.py`
   → 127.0.0.1:54321), so the forwarder made every probe look like a
   loopback client; the storm was transport-independent.
2. **Unbounded encoder rate control.** Production used VideoToolbox
   `Quality` mode only (0.92 at "high"). With Quality set, VT ignores both
   `AverageBitRate` and `DataRateLimits` (already proven by the 08-15 audit
   receipts), so motion bursts were unbounded → the historical 34-39 fps
   collapses + tablet decoder input-buffer starvation + keyframe cascades.
3. **Dead-socket send plateau.** On connection failure the server kept
   `connectionReady=true` and kept encoding+sending into the corpse — the
   "dropped: 35-40" plateaus after every reset, wasted CPU until the idle
   pause kicked in.

## Fixes (MacHost only; no APK change needed)

### StreamingServer.swift
- **Liveness-gated takeover.** While a live client is streaming, a new
  connection is held as a *contender*: it must send its first byte within
  1.5 s (real clients advertise decoder limits/metadata immediately) to be
  promoted; silent probes are rejected WITHOUT touching the live stream.
  Version-proof: works against every deployed client version because it
  discriminates on behavior (speak vs. silent), not protocol version.
- **Dead-socket hygiene.** `.failed`/`.cancelled` now clear
  `connectionReady`, reset the receive loop, and fire `onClientDisconnected`
  once — with identity guards so a replaced connection's terminal callback
  cannot tear down its successor (same pattern the control channel already
  had).

### VideoEncoder.swift
- **Bitrate-bounded rate control.** Quality mode removed entirely.
  `AverageBitRate` = preset target, `DataRateLimits` = hard cap at 1.5x over
  a 1-second window. Preset ladder (Mbps avg/cap): ultralow 6/9, low 12/18,
  medium 20/30, **high 30/45**, extrahigh 40/60, max 50/75, ultra 60/90.
  gamingBoost = ultralow (bounded fast profile). `SideScreen_exp_bitrate`
  (Mbps) overrides the target; UI bitrate acts as a floor when in the sane
  100-2000 Mbps UI range (legacy Kbps-scale values like the paused
  campaign's 8000 are ignored).
- **GOP stays 1 s** (frameRate). Tried 5 s and 2 s live on 2026-08-16: the
  deployed client's stale-keyframe detector (1.5 s) fires regardless, which
  desynchronizes forced IDRs from the encoder's budget — worse than a
  steady 1 s GOP whose burst cost is now capped by DataRateLimits.

Not enabled: FrameSkipper (SHA-256 per-frame hash on the capture thread
would add jitter to buy back ~2-3 Mbps of mostly-static localhost/VPN
traffic; the bounded encoder already spends almost nothing on static
content — measured 1.6-5.3 Mbps total on a quiet desktop).

## Verification (live, tablet SM-X800 over E3/VPN path, 2800x1752@60)

- Held-left-button circle stress test (ledger §"Reproduction test", 960
  points, center retargeted to the virtual display at (2212,438), r=250):
  - Pipeline: **55.8-58.2 fps sustained**, 9.7-10.2 Mbps steady,
    dropped: 0 in every window, frame age 30-39 ms flat (previous collapse:
    34-39 fps at the same ~10 Mbps with climbing drops and a client reset).
  - Earlier lighter run: 56-60 fps, frame age 10-17 ms.
  - Android decoder: latency avg 8.4-9.9 ms / max ≤23.7 ms, dropped=0,
    input-buffer waits ≈ 0, zero timeouts, **zero client keyframe requests**.
- Probe immunity: silent `nc 127.0.0.1 54321` against the live stream →
  "new connection held as contender until it speaks" → stream unaffected,
  still streaming, dropped: 0.
- Stability watch: 0 resets in 2 minutes of steady streaming (vs. one reset
  every 2 s during the storm).
- `swift test`: 35/35 pass. Release build clean.

## Runtime profile (unchanged from pause point except as noted)

Same as `2026-08-15-sharpness-investigation-paused.md` plus
`SideScreen_exp_brightness=1 SideScreen_exp_idleSleep=1
SideScreen_exp_idleSleepSecs=10` (idle pause verified working: capture
pauses ~10 s after the last client leaves, resumes on connect).
Sender binary deployed via supervisor restart into
`~/vd_campaign/120hz_attack/exp_bin/SideScreenExp.app` (TCC-inherited
context — restart only through `/tmp/sidescreen_supervisor.cmd`).

## Known remaining quirks (not fixed today)

- After a sender restart the Android app waits on its disconnected UI; the
  video connection needs a CONNECT tap (checklist keeps probing meanwhile —
  now harmless). An auto-reconnect on the client would remove the tap.
- The app's checklist probe still targets the video port; with the contender
  gate it is harmless, but probing the control port (54327) would be
  cleaner in a future APK.
- Frame age at high-entropy motion (~30-39 ms) is consistent but higher than
  the light-content case; bounded rate keeps it flat rather than spiky.
