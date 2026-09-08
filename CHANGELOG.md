# Changelog

## Unreleased

### Adaptive high-refresh USB pacing (experimental branch)

- Added a wired adaptive FPS pipeline for high-refresh sessions while keeping ScreenCaptureKit hot at the configured maximum (up to 120 Hz).
- Clean desktop frames now progressively reduce encode/send/decode work (up to 60 -> 30 -> 15 FPS) using ScreenCaptureKit dirty-rect metadata, with immediate full-motion wake-up and fail-open handling when metadata is unavailable.
- Added load-side 120 -> 90 -> 60 motion adaptation using Network.framework send overlap and `contentProcessed` timing, with asymmetric recovery hysteresis and failed-probe backoff.
- Corrected a false-congestion assumption: a frame larger than currently available TCP send-buffer headroom is not sufficient evidence of overload; critically low headroom is now only a corroborating signal.
- Added deadline-carry cadence control so 90 FPS on a 120-Hz source produces a true 3-of-4 cadence instead of aliasing toward 60 FPS.
- Added connection-generation fencing and mid-session source-ceiling resets for the adaptive controller.
- Android now prefers the highest advertised same-resolution display refresh rate up to 120 Hz and requests minimal post-processing where supported; refresh selection is covered by pure JVM tests.
- Added deterministic Swift tests for idle pacing, motion pacing, congestion hysteresis, ramp backoff, reconfiguration, and longer marginal-path simulations.
- Added `docs/adaptive-usb-fps.md` with the design, evidence boundaries, and hardware-validation requirements.

