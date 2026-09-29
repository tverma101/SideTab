# No video on the tablet, control reconnects, slow decoder (2026-09-29)

## Symptom

After the Mac host and the tablet were updated from the integrated stack, a USB
session connected and stayed "connected", but the tablet never showed the Mac
desktop. The control socket also reconnected about every 15 seconds. It had
first looked like a problem with the old APK only (see
[legacy-decoder-limits-tag-2026-09-29](legacy-decoder-limits-tag-2026-09-29.md)),
but fresh builds on both sides behaved the same way.

## Evidence

- `nettop` on the host process during a live session: the video socket had sent
  **126 bytes** in total. That is the display config and codec handshake, and
  not a single frame.
- `~/Library/Logs/SideScreen/sidescreen.log` had no `First keyframe accepted
  for new client` line for any session since at least the evening of
  2026-09-28. The server gates the stream on that first keyframe.
- A standalone VideoToolbox probe printed each encoded sample's attachments:
  - IDR (H.264): `[DependsOnOthers: 0]`, with **no** `NotSync` key;
  - IDR (HEVC): the same, plus `HEVCSyncSampleNALUnitType`;
  - P-frame: `[NotSync: 1, DependsOnOthers: 1]`.
- Android `logcat`: the client sent a control ping every second, but after the
  first one no further pings went out. The socket closed on the 15 s pong
  timeout and reconnected, over and over.
- Android `logcat` at connect: two decoder builds were started, the first was
  retired, and the second logged a failed low-latency configure before it fell
  back.

## Root causes

### 1. Keyframes were read as P-frames (Mac)

`VideoEncoder.isSyncSample` required an explicit `NotSync = false` attachment.
CoreMedia defines a **missing** `NotSync` key as a sync sample
(`CMSampleBuffer.h`: "absence of this key implies Sync"), and that is exactly
how VideoToolbox marks its IDRs. Every keyframe was therefore reported as a
P-frame. `StreamingServer.sendEncodedFrame` drops every non-keyframe until it
has sent a first keyframe (`frameWaitingForSync`), so the whole stream was
dropped.

This came from the 2026-09-25 audit commit `5d83719`, whose CHANGELOG line
claimed the previous check "failed open" and marked P-frames as IDRs. That
claim does not hold for VideoToolbox, which always sets `NotSync = true` on
dependent frames.

### 2. Control pongs never matched (Android)

Commit `fd52697` (2026-09-28) moved the pong deadline so that it is armed only
after the write returns. It also started recording that post-write time as the
probe's match key (`OutstandingPing(transport.generation, now)` became
`OutstandingPing(transport.generation, System.nanoTime())`). The packet itself still carried the pre-write timestamp,
which is what the host echoes. No pong ever matched, so the first probe stayed
outstanding, `sendPing` sent nothing further while a probe was outstanding, and
the 15 s timeout closed a healthy socket.

### 3. Every connect built the decoder twice (Android)

The host sends the display config twice on connect ("Client capability update -
re-sending display config"). Each copy started a background decoder build
before the first had published. The second request retired the first build,
which already held the surface, so the second build's low-latency configure
failed and it fell back to a slower configuration.

## Failed attempts and misdiagnoses

- **"The old APK is the problem."** The legacy tag 11 record is real and its
  back-compat stays, but it was not the blocker. The host itself never sent a
  frame to any client, old or new.
- **"The decoder race drops the stream."** The duplicate build is wasteful and
  loses low latency, but the stale build is discarded correctly. It does not
  explain a black screen.
- **Reading the host log while `swift test` ran.** Test runs wrote their own
  `debugLog` lines (`Dirty-rect gate`, `Annex-B walk`, a burst of `USB adaptive
  FPS` lines) into the live log, which muddied the evidence.

## Fixes

- `VideoEncoder.isSyncSample` follows the CoreMedia contract: an absent key, or
  no attachments at all, is sync, and only a present key with a non-Boolean
  value is treated as not sync.
- `ControlChannel` keeps two times in `ControlPingProbe`: the wire timestamp for
  matching and the arming time for the deadline. `StreamClient` now logs whether
  a video pong answers the latest probe, instead of `matched=false`
  unconditionally.
- `MainActivity` keys each decoder build on its full request
  (`VideoPipelineKey`). An identical request while a build is in flight is a
  no-op and logs `initializeDecoder skipped — an identical decoder build is
  already running`.
- `AsyncDebugLogger` writes to `$TMPDIR/SideScreenTests/Logs/` in a test
  process, so `swift test` no longer touches the live log.

## Validation

- Tests:
  - `VideoEncoderWireFormatTests.testKeyframeDetectionFollowsCoreMediaContract`;
  - `testRealEncoderFlagsItsFirstFrameAsKeyframe`, which drives a real
    VideoToolbox H.264 session and checks that the first output is flagged as a
    keyframe and starts with an SPS;
  - `ControlPingProbeTest`;
  - `AsyncDebugLoggerTests`.

  The keyframe tests fail against the old logic.
- Live USB session on the SM-X800, with both devices freshly installed from
  `local/install-2026-09-29`:
  - `First keyframe accepted for new client`, and the Mac desktop is visible on
    the tablet;
  - one pong a second with no control reconnects;
  - a single decoder build that keeps low latency. The first decoded output
    arrived about 120 ms after connect, and decoder latency averaged 11.4 ms
    (max 58.8 ms);
  - touch swipes scroll the Mac at 50–56 fps, with 20–30 ms frame age and no
    drops;
  - the power policy requests 120 Hz on external power, and brightness is
    applied.
- `swift test` leaves `~/Library/Logs/SideScreen/sidescreen.log` untouched.

## Residual gaps and revalidation triggers

- **USB adaptive FPS (#56) settles at 60 and does not climb back.** At connect
  it steps 120 → 90 → 60 on `encodeAge`, and no `healthy ramp` line follows,
  even during sustained motion. The encode-age floor at 120 FPS (25 ms) sits
  inside this machine's normal capture-to-encode age (20–30 ms). Any pressure
  sample at the 60 tier silently resets the healthy-completion count, because a
  step-down from 60 is impossible and so nothing is logged. Needs a design
  decision on #56.
- About 13 s passed between tapping Connect and the connection, right after an
  APK install re-established `adb reverse`. Not yet explained.
- The audit commit `5d83719` claimed to fix "60+ defects". Two of its changes
  are now confirmed regressions: keyframe detection (above) and the virtual
  display's density
  ([oversized-hidpi-display-2026-09-29](oversized-hidpi-display-2026-09-29.md)).
  Its other changes have not all been re-verified live.
- Re-run the live checklist above after any change to `VideoEncoder`'s output
  callback, the control ping path, or `MainActivity` decoder setup.
