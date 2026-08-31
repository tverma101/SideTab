# Codex turn log

## 2026-08-30 — Android bridge hardening

- Goal: continue Android bug fixing with proper tests, truthful checklist
  evidence, and a real Mac mode/transport bridge.
- Canonical target: tverma101/SideScreen, isolated worktree branch
  codex/android-bridge-hardening, based on the clean runtime snapshot
  85985cdc7b7dfb44a7e611fc810f459028dd28d9.
- Inspected: open PRs #52, #53, #54 for Android storage/session/repository
  hardening; PR #43 remains rejected/partial and was not revived.
- Integrated reviewable foundations: encrypted pairing storage and QR lifecycle,
  serialized session/brightness ownership, repository/frame tests, and local
  CI/release contracts from those PRs.
- Changed: Android StreamClient/MainActivity/WirelessTabController, mode
  handshake/checklist/layout policy, Android tests/layout; Mac
  StreamingServer/AppDelegate/ConnectionMode and mode tests; Swift parallel
  defaults test; repository cross-language contract test.
- Behavior: mode is admitted at the Mac route boundary; USB is loopback-only,
  Wireless is LAN-only plus auth; connected UI waits for display/frame evidence;
  idle checks never probe the Mac; SurfaceView stays panel-sized.
- Validation: Android `testDebugUnitTest lintDebug assembleDebug` passed;
  Swift `swift test -c debug --parallel` and `swift build -c release` passed;
  Python unittest discovery passed (13 tests); `git diff --check` passed.
  Android lint completed with warnings only. Earlier Android compile caught an
  internal/public callback mismatch and was corrected before the passing run.
- Evidence state: implemented and locally tested. Not installed, live-tested,
  or user-confirmed on USB/Wireless/tablet hardware in this turn.
- Residual gap: target-device bridge, rotation/fit, reconnect, wrong-route,
  decoder/power, and installed-artifact acceptance remain.
- Authoritative troubleshooting record:
  docs/troubleshooting/android-bridge-hardening.md.

## 2026-08-30 — Android bridge second-round hardening

- Goal: continue on the saved hardening branch after the first round; close
  recovery, route-admission, control-channel, display-metadata, and misleading
  checklist gaps without reviving PR #43.
- Canonical target: tverma101/SideScreen; work remained isolated in
  /Users/tejas/Projects/SideScreen-android-bridge-hardening on
  codex/android-bridge-hardening. The canonical checkout and PR #43 were not
  edited, installed, pushed, merged, or run through Actions.
- Changed: Android StreamClient now bounds pre-display admission reads,
  validates display geometry/transform data, authenticates the Wireless
  control socket, preserves actionable protocol errors, and exposes Cancel
  while connecting or waiting for the first frame. Android checklist evidence
  distinguishes verified streaming from legacy/unverified streaming.
- Changed: Mac StreamingServer now sends explicit wrong-route admission
  results, gates control sockets by route and Wireless token, preserves the
  active control client while a candidate authenticates, and validates USB
  contenders or authenticates Wireless contenders before takeover. Added the
  pure ConnectionAdmissionProbe policy and tests for fragmented, malformed,
  wrong-mode, wrong-route, legacy, and recognized protocol proofs.
- Documentation: expanded the issue record with the second-round failure modes,
  control-channel map, resource-impact notes, and acceptance gaps.
- Validation: Android Gradle unit tests, lint, and debug assembly passed; Mac
  Swift tests passed with 69 tests and the release build passed with only
  pre-existing warnings; repository Python tests (13) and the final diff check
  passed.
- Evidence state: implemented and locally tested. Not installed, live-tested,
  visually checked on the SM-X800, or user-confirmed on USB/Wireless hardware.
- Residual gap: run the explicit USB/Wireless wrong-route, reconnect, control
  failover, display-fit/rotation, and sustained CPU/GPU/power scenarios on the
  target devices after review.
