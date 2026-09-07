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
  payload into outstanding wireless sends. TCP send-buffer headroom adds a
  short, self-expiring pause before more routine capture is encoded. Forced
  sync frames may bypass this budget during startup or recovery.
- ScreenCaptureKit's explicit clean-frame metadata can suppress unchanged
  wireless frames. Frames with unknown metadata are encoded, and synthetic
  pixel-mutating experiments bypass the clean-frame gate.
- After the initial sync frame, encoded reference frames are kept in order;
  congestion suppresses work before VideoToolbox instead of dropping a P-frame
  from the codec reference chain.
- The Android client binds video and the dedicated control channel to the same
  Wi-Fi network when Android exposes a Wi-Fi `Network` handle. The video socket
  has a bounded receive-buffer hint and a 256 KiB input buffer.
- The Android decoder targets 60 Hz and drops decoded wireless output older than
  two 60 Hz intervals (33.33 ms), while releasing the codec buffer normally.
  This bounds visible staleness without breaking the H.265 reference chain.

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
