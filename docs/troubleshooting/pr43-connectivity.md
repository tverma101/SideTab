# PR #43 connectivity troubleshooting record

## Symptom

Tapping **Connect** could leave the Android client black or terminate its
activity. The reported case was USB, not wireless. The stream could also use a
stale paired wireless address, and the Android picture could retain a black
strip after the connection became active.

## Root cause

The USB failure was a teardown and readiness race with four independent
failures:

1. `clearPresentationSurface()` called `TextureView.setBackgroundColor()`.
   Android rejects a background drawable on `TextureView`, so cleanup raised
   `UnsupportedOperationException` and the process was force-finished.
2. The same cleanup path called `SurfaceHolder.lockCanvas()`. That claimed the
   SurfaceView buffer queue as a CPU producer; the following EGL/MediaCodec
   producer then failed with “already connected.”
3. Decoder construction published `Failed` but left the socket alive, allowing
   a half-connected generation to continue receiving frames without a usable
   video path.
4. The GPU bridge queried its EGL window surface before fullscreen presentation
   hid system bars. It kept the inset height (`2800×1586`) after the actual
   SurfaceView expanded to `2800×1752`, which rendered a black strip.

The transport issue was separate: the wireless client could retain an old LAN
address after the Mac changed networks, and the Mac listener did not
previously enforce the selected transport at the socket boundary.

## Recovery implemented

- Cleanup now releases the current generation, closes its client, releases the
  decoder/renderer, and hides both presentation surfaces without claiming a
  Canvas buffer.
- Decoder failure and first-render timeout invalidate and close the matching
  transport, return to the Android shell, and provide a retryable reason.
  `Streaming` is entered only after a current-generation rendered frame.
- USB accepts only the ADB-reverse loopback route. Wireless is advertised and
  admitted only as an authenticated non-loopback LAN session. There is no
  cross-transport fallback.
- The SGSR and CfL EGL paths re-query their live window surface dimensions so
  fullscreen/inset changes update the viewport before the next frame.
- Wireless reconnect prefers bounded Bonjour discovery when an automatic retry
  follows a network failure, while still retaining the paired endpoint as a
  bounded fallback.

## Validation

Local source validation passed:

- Mac `swift test`: 68 tests, 0 failures.
- Android `./gradlew test assembleDebug`: build successful; 71 Gradle tasks,
  including the Android unit-test suites.
- Mac transport-admission tests cover USB loopback-only and wireless
  non-loopback-only acceptance.

Installed USB validation on the SM-X800 used the canonical installed host at
`/Users/redacted/Applications/SideScreen.app` and the debug APK. A fresh connect
kept the Android process alive, connected to `127.0.0.1:54321`, negotiated
`2800×1752`, started the HEVC decoder, and produced a first output frame. The
renderer logged the expected transition from `2800×1586` to `2800×1752`; a
tablet screenshot then showed the Mac desktop filling the panel with no black
top strip.

The Mac stream was stopped to force a transport teardown. Android received
EOF/disconnect, destroyed the old SurfaceView, remained in `MainActivity`, and
did not crash. The Mac listener was started again and a second USB tap
reconnected to `127.0.0.1:54321`, produced a fresh first output frame, and
filled the tablet panel again.

## Residual gap

The wireless stale-endpoint failure and transport admission are covered by
source tests and bounded local checks, but a fresh physical wireless stream
cycle was not run in this receipt. Mac lock/sleep, Android screen-off/on, and
long-cycle hardware acceptance remain separate from this USB proof. The first
encoded frame can arrive while the decoder is being created; the client
requests a fresh keyframe and the tested run rendered the first usable frame
within the bounded readiness window.

## Rollout link

The delivery receipt is maintained in
[docs/codex/turn-log.md](../codex/turn-log.md). PR #43 remains open and Draft;
this record does not authorize a merge or hosted Actions run.
