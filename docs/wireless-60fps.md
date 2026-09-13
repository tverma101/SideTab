# Wireless 60 FPS path

Side Screen's wireless session is a bounded real-time display path. The
wireless profile is resolved when the Mac starts the server; it does not rewrite
the user's persisted USB settings.

## Runtime contract

- Capture and encode cadence is capped at 60 FPS. A 90/120 FPS USB preference
  does not make a wireless session run faster than the tablet path can present.
- VideoToolbox uses the selected quality preset with a 40 Mbps average wireless
  ceiling and a 60 Mbps one-second peak ceiling. The historical USB bitrate
  control and experimental bitrate override cannot raise that wireless cap.
- The Mac admits no more than two routine encoded frames or 6 MiB of encoded
  payload into outstanding wireless sends. A usable, non-zero TCP send-buffer
  headroom sample can add a short, self-expiring pause before more routine
  capture is encoded; a zero sample is treated as unavailable metadata rather
  than as proof that a healthy route is full. The in-flight frame/byte budget
  remains the hard safety boundary. Forced sync frames may bypass this budget
  during startup or recovery.
- ScreenCaptureKit's explicit clean-frame metadata can suppress unchanged
  wireless frames. Frames with unknown metadata are encoded, and synthetic
  pixel-mutating experiments bypass the clean-frame gate.
- After the initial sync frame, encoded reference frames are kept in order;
  congestion suppresses work before VideoToolbox instead of dropping a P-frame
  from the codec reference chain.
- The Android client sends video and dedicated control traffic through the same
  Wi-Fi `Network` when Android exposes a handle, preferring that network's
  `SocketFactory` and retaining process-default plus legacy `bindSocket`
  fallbacks for OEM compatibility. The video socket has a bounded
  256 KiB receive-buffer hint and a 64 KiB input buffer. The app buffer is
  deliberately smaller than a frame burst so TCP read-ahead cannot turn
  transient decoder pressure into visible stale content.
- The Android decoder targets 60 Hz and drops decoded wireless output older than
  two 60 Hz intervals (33.33 ms), while releasing the codec buffer normally.
  This bounds visible staleness without breaking the H.265 reference chain.
- For wireless, the Android activity keeps the panel awake only while connected,
  does not hold a partial CPU wake lock, and advertises the source cadence to
  SurfaceFlinger. A device with a seamless 60-Hz mode may therefore avoid
  running a 120-Hz panel for wireless video; devices without that mode keep
  their existing mode. USB keeps its legacy display/wake-lock behavior.

## Efficiency decisions

- The Mac wireless path uses a dedicated serial ScreenCaptureKit sample queue
  and a four-frame capture queue. This keeps capture callbacks ordered while
  removing one frame of avoidable buffering; it does not change the physical
  pixel size, codec, bitrate ladder, or color range. USB keeps the legacy
  callback-queue behavior.
- Wireless ScreenCaptureKit idle/blank callbacks are treated as heartbeat
  metadata and do not re-encode the last pixel buffer. The cached buffer is
  retained only for an explicit reconnect/keyframe replay, so an unchanged
  desktop does not burn encoder, network, or Android presentation power. USB
  retains its legacy cached-frame fallback.
- Wireless TCP pressure is a headroom signal, not a requirement that the kernel
  already have room for a complete encoded frame. Network.framework can stream a
  frame larger than the current free window; the sender still limits outstanding
  frames and bytes, so this avoids the old self-inflicted every-other-frame
  throttle without permitting an unbounded queue. A zero headroom sample is
  ignored because it is not reliable on every healthy IPv6 Wi-Fi route.
- VideoToolbox remains real-time, no-B-frame, bitrate-bounded encoding. The
  Android path remains hardware MediaCodec to SurfaceView; no post-processing or
  resolution reduction is used as a substitute for throughput.
- When no tablet is connected in wireless mode, the Mac's idle monitor pauses
  ScreenCaptureKit after its grace period and releases the display-sleep
  assertion. This is enabled by default for wireless sessions; set
  `SideScreen_exp_idleSleep=false` to restore wireless always-capturing
  behavior. USB remains on the legacy always-capturing path.

## Native Android presentation

The default Android path is the hardware decoder feeding a `SurfaceView` with
native `MediaCodec` scaling. VSR/CfL are opt-in post-processing paths; they are
not required for wireless operation and can be disabled when native fidelity
or lowest power matters more than enhancement.

## Validation boundary

The policy is covered by host Swift tests and Android JVM tests:

```bash
swift test --package-path MacHost
(cd AndroidClient && ./gradlew testDebugUnitTest --no-daemon)
```

Those tests prove the policy and transport state transitions. A sustained
60-FPS wireless claim still requires a live run with the Mac and Android device
on the same trusted Wi-Fi network, with the Android stats overlay and host logs
showing the resulting FPS, bitrate, stale-output drops, and reconnect behavior.

## Paused implementation checkpoint — 2026-09-11

- Source-side Android power/display changes, bounded receiver buffers, Mac idle
  capture sleep, capture queueing, and transport diagnostics are implemented.
- The installed diagnostic build connected over the home Wi-Fi IPv6 route and
  proved the Android hardware decoder path: 60-Hz hint, 2800x1752 hardware HEVC,
  approximately 3 ms read-loop callbacks, zero decoder drops, and approximately
  12 ms decode latency. The same run showed ScreenCaptureKit delivering 60-Hz
  callbacks and correctly labeling no-pixel callbacks as `idle`.
- That installed run also isolated the remaining host-side admission defect:
  the route reported `tcpAvailable=0`, causing the old metadata pause to count
  hundreds of `pressureSkips` despite only one send in flight and a healthy
  decoder. The source now treats a zero sample as unavailable metadata and has
  a regression test for it.
- The zero-sample source guard passed the Mac suite (66 tests, 0 failures), but
  the release rebuild was deliberately stopped during the x86_64 build before
  that guard was installed. Wireless 60-FPS acceptance therefore remains
  paused at the source-tested/install-pending boundary.
