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
