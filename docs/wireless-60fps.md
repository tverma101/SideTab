# Wireless 60 FPS path

SideTab's wireless session is a bounded real-time display path. The
wireless profile is resolved when the Mac starts the server; it does not rewrite
the user's persisted USB settings.

## Runtime contract

- Capture and encode cadence is capped at 60 FPS. A 90/120 FPS USB preference
  does not make a wireless session run faster than the tablet path can present.
  ScreenCaptureKit is asked for twice the display rate (1/120 s): an interval
  equal to the 60 Hz display period aliases against it and delivers about 50
  complete frames per second.
- VideoToolbox uses the selected quality preset with a 40 Mbps average wireless
  ceiling and a 60 Mbps one-second peak ceiling. The historical USB bitrate
  control and experimental bitrate override cannot raise that wireless cap.
- The Mac admits no more than two routine encoded frames or 6 MiB of encoded
  payload into outstanding wireless sends. `availableSendBuffer` is the number
  of bytes still queued in the kernel send buffer (0 when idle), not free space.
  More than 64 KiB queued beyond the frame just handed over adds a 20 ms
  self-expiring pause before more routine capture is encoded. The in-flight
  frame/byte budget remains the hard safety boundary. Forced sync frames may
  bypass this budget during startup or recovery.
- ScreenCaptureKit's explicit clean-frame metadata can suppress unchanged
  wireless frames. Frames with unknown metadata are encoded, and synthetic
  pixel-mutating experiments bypass the clean-frame gate.
- After the initial sync frame, encoded reference frames are kept in order;
  congestion suppresses work before VideoToolbox instead of dropping a P-frame
  from the codec reference chain. A frame too large for the wire format breaks
  the chain, so the Mac then holds P-frames and requests a fresh IDR.
- ScreenCaptureKit sends nothing for a still screen, so after motion stops
  the Mac may re-encode the newest changed frame at 80, 250, 600, 1200 and
  2000 ms (`WirelessSettleRefreshPolicy`). A step encodes when the change
  never produced encoder output (a pressure skip or a VideoToolbox drop), or
  while the previous output was large enough that the encoder still has
  detail to add. A window switch refines for several steps; a keystroke,
  scroll or cursor blink does not. The 600 ms step always re-sends the
  settled frame once if nothing else did (~1-2 KB), so a receiver that lost
  the final frame still shows it.
- The 600 ms step becomes an IDR only when the last keyframe is at least
  25 s old. The periodic fallback GOP is 30 s, which only matters during
  unbroken motion. A 2800x1752 IDR is 430-900 KB. With the old 5 s rule,
  light use sent one every ~7 s, and on a weak link each one stalled the
  send for up to 1.8 s. Every send stall over 100 ms in that session came
  with a frame over 240 KB. The Android wireless stale-keyframe watchdog
  waits 32 s to match. USB keeps 6 s.
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
  The newest frame fed to the decoder always renders, however late: a newer
  picture does not exist, and dropping it left the end of a scroll or
  keystroke missing until something else moved.
- The Android activity keeps the panel awake only while a stream is active and
  the app is visible. It does not hold a partial CPU wake lock; Android may turn
  the display off when the app leaves the foreground. A foreground wireless
  stream holds a `WIFI_MODE_FULL_LOW_LATENCY` Wi-Fi lock, which turns off
  802.11 power save while it is held. Android honours it only for a visible
  app with the screen on, and it is released with the rest of the session. Wireless also advertises
  the source cadence to SurfaceFlinger. A device with a seamless 60-Hz mode may
  therefore avoid running a 120-Hz panel for wireless video; devices without
  that mode keep their existing mode.

## Efficiency decisions

- The Mac wireless path uses a dedicated serial ScreenCaptureKit sample queue
  and a four-frame capture queue. This keeps capture callbacks ordered while
  removing one frame of avoidable buffering; it does not change the physical
  pixel size, codec, bitrate ladder, or color range. USB keeps the legacy
  callback-queue behavior.
- Wireless ScreenCaptureKit idle/blank callbacks are treated as heartbeat
  metadata and do not re-encode the last pixel buffer. Beyond the settle
  refreshes above, the cached buffer is used only for an explicit
  reconnect/keyframe replay, so an unchanged desktop does not burn encoder,
  network, or Android presentation power. USB retains its legacy cached-frame
  fallback.
- The "avg frame age" diagnostic reads near 0 ms (on USB too). With the 2x capture
  interval, ScreenCaptureKit stamps frames with the upcoming display time, a
  few ms in the future, and the age calculation fails closed to "now".
- VideoToolbox remains real-time, no-B-frame, bitrate-bounded encoding. The
  Android path remains hardware MediaCodec to SurfaceView; no post-processing or
  resolution reduction is used as a substitute for throughput. Encoding below
  native and upscaling on the tablet was measured and rejected for desktop
  content. At `SideScreen_encodeScale=0.75` (2100x1314), scrolling text frames
  grew from ~20 KB to ~85 KB and the stream hit the 40 Mbps cap. Pressure skips
  rose from 0.1% to 7.6%, and decode latency rose from 11.2 to 13.8 ms.
  Non-integer resampling changes text pixels every frame, which defeats motion
  compensation. Native HiDPI scrolling is a pure translation.
- When no tablet is connected in wireless mode, the Mac's idle monitor pauses
  ScreenCaptureKit after its grace period and releases the display-sleep
  assertion. This is enabled by default for wireless sessions; set
  `SideScreen_exp_idleSleep=false` to restore wireless always-capturing
  behavior. USB remains on the legacy always-capturing path.

## Native Android presentation

The default Android path is the hardware decoder feeding a `SurfaceView` with
native `MediaCodec` scaling. At native size the video layer is a hardware
overlay (`dumpsys SurfaceFlinger` shows `DEVICE` composition with a
2800x1752 source crop on a 2800x1752 frame), so the panel shows the stream
1:1. `adb screencap` goes through GPU composition instead. That path insets
the decoder's padded 1760-row buffer by one texel, so a screencap looks
stretched by 0.1% vertically even though the panel is not. VSR/CfL are opt-in post-processing paths; they are
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

## Live validation — 2026-10-06

Galaxy Tab S8+ on home Wi-Fi (IPv6), 2800x1752 HEVC, 30 s scrolling-text
workload: 59.5 FPS mean, 0.1% pressure skips, 3 stale drops, 11.2 ms mean
decode latency, send p95 0.3 ms, ~10 Mbps. The baseline before this work was
~52 FPS with 7% pressure skips. Run history and the method are in project
memory (`pmem search "wireless optimization 2026-10-06"`).
