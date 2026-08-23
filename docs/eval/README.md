# Runtime evaluation receipts

The dated JSON receipt in this directory is the machine-readable provenance
for an installed evaluation run. It records the source snapshot commit, the
Mac bundle identity/CDHash, the Android APK SHA-256 and installed package,
local test results, and the hardware run boundary.

Build outputs (`SideScreen.app`, DMGs, APKs, and `.build`) are intentionally
not committed. A receipt may be added in a follow-up commit after the source
snapshot is built and installed; `snapshot_commit_sha` is the commit that
produced both binaries, while `receipt_commit_sha` identifies the commit that
published the evidence record.

For macOS launch diagnostics, use the installed executable directly with
`--headless`; this keeps the test process from taking focus or presenting the
Settings window. A normal Finder/DMG launch remains the user-facing path.

## Measurement labs

The snapshot also contains opt-in measurement drivers for the next evaluation
phases. They do not change production defaults or choose a codec profile:

- `scripts/run-quality-lab.sh` generates deterministic 2800x1752 PNGs, renders
  the same image natively on Android, captures the native or active streamed
  `SurfaceView` with `PixelCopy`, and emits RGB error/PSNR/luma/chroma-proxy
  reports. Streamed capture waits for the stream-only fullscreen surface and
  rejects a pre-first-frame control-shell surface with the wrong dimensions.
  The native and streamed PNGs are digital-path evidence; panel photography
  remains a separate boundary.
- `scripts/run-smoothness-lab.sh` enables the Android private raw trace writer
  for an already-active USB or wireless session. It emits frame timestamps,
  cadence percentiles, duplicate/skipped/reordered frame counts, freshness,
  decoder queue time, and an optional Perfetto trace. When `--perfetto` is
  requested, `run-metadata.txt` records `perfetto_status=collected` or
  `perfetto_status=unavailable`; the latter keeps `perfetto.stderr` so a
  retail-device permission or tooling limitation is explicit.
- `scripts/run-host-contention-lab.sh` samples the exact installed SideScreen
  PID, WindowServer, total CPU, memory free percentage, swap, and thermal state
  for a user-labelled W0-W5 workload. It never launches or closes the user's
  browser, media player, editor, terminal, or build.

The deterministic motion source is enabled only with
`defaults write com.sidescreen.app SideScreen_lab_motion_fps -int 60` (or a
different tested cadence). It is generated after the ScreenCaptureKit admission
point, so it is useful for encoder/transport/Android presentation cadence but
does not replace real-desktop #19/#28 capture and contention runs. Remove the
key after a run. None of these tools claims the external 240-FPS camera gate.

Example native digital-path run:

```bash
./scripts/run-quality-lab.sh --serial R52X30G5TNB --mode native --pattern static-ui
```

Example smoothness run after the desired transport is already connected:

```bash
./scripts/run-smoothness-lab.sh --serial R52X30G5TNB --duration 30 --target-fps 60 --perfetto
```

Example host run while the user holds a W2 media-content workload:

```bash
./scripts/run-host-contention-lab.sh --scenario W2-media --duration 60
```
