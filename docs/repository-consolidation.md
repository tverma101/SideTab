# Repository consolidation

Updated 2026-09-29.

## Canonical repository

The canonical public repository is [tverma101/SideTab](https://github.com/tverma101/SideTab), renamed from `tverma101/SideScreen`. GitHub retains the repository's branches, issues, pull requests, and releases when its name changes. The existing SideScreen issues therefore remain attached to SideTab.

`tverma101/TabletBridge` had no issues, but it did have an open 30-commit pull request (#1) with a 15-file runtime-efficiency patch. Its source history is independent of SideScreen's history and is based on an older code snapshot. To preserve it without rolling back newer session and transport hardening, the complete PR head is kept on the public archive branch `archive/tabletbridge-pr-1-pre-consolidation` at commit `686454e465bb146298b8c8bd0e59c446dbfc3c14`. The archive branch is not part of the live implementation; review individual changes before porting them.

Deleting the TabletBridge repository closes its open pull request. The archive branch retains its commits and source tree, but not the pull request's review discussion or metadata.

## Compatibility identities

The user-facing product name is SideTab. The following existing identifiers remain unchanged so this rename does not create a new app identity or wire protocol:

- macOS bundle identifier: `com.sidescreen.app`
- legacy macOS `CFBundleName` and designated signing requirement, retained for Screen Recording permission continuity; the visible bundle name is SideTab
- Android application ID and namespace: `com.sidescreen.app`
- QR pairing scheme: `sidescreen://`
- Bonjour service type: `_sidescreen._tcp`
- existing preference keys, executable name, and `SideScreen.app` install path

The legacy website domain `sidescreen.dev` also remains in use.

## Local work integration (2026-09-29)

Every branch and stash that existed only locally was either landed on the SideTab stack or given an explicit decision below. **Nothing was deleted.** Each branch is still on `origin` and both stashes are intact, so any of the no-fit items can be revisited.

The live stack, bottom to top: `main` ← #75 `codex/rename-sidestab` ← #72 `fix/session-lifecycle` ← #73 `feat/input-source` ← #74 `perf/frame-signposts`. On top of #74 sit #76 `perf/settings-runtime-isolation` and #77 `feat/android-power-policy`, and #56 `adaptive-usb-fps` sits on #77.

### Landed

| Source | Where | Notes |
|---|---|---|
| `wired-cpu` branch (5 commits) | #76 | Runtime and metrics state split out of `DisplaySettings`, so ticks no longer relayout the settings form. |
| `codex/power-policy-wip-20260928` | #77 | Power-source-aware refresh and screen-off idle teardown. The WIP's decoder operating-rate change was not taken; see #77. |
| PR #56 `adaptive-usb-fps` | #56, retargeted onto #77 | Integration decisions are recorded at the top of `docs/adaptive-usb-fps.md`. |
| `stash@{0}` (crash fixes, 2026-08-15) | #75 | `showError` guard ported. Its slider-snap half was already covered by `PreferencesManager.snapToStep`. |

### Not ported, with reasons

The August line forks from `4467484` (2026-08-21). `eval/runtime-snapshot-2026-08-23` is its base: 52 commits, which include all of `fix/adaptive-refresh-governor`. It is **a parallel evolution of the codebase, not a patch set.** Measured against the stack top, `MainActivity` differs by about 2,400 changed lines and `StreamClient` by about 1,800. It adds whole subsystems the stack does not have, several of which compete with designs the stack has since landed.

| Branch | Decision | Reason |
|---|---|---|
| `exp/wireless-60fps-freshness` (draft #38) | Superseded | `WirelessFreshnessPolicy` is on both sides of the stack in an evolved form; see `docs/wireless-60fps.md`. |
| `fix/android-foundation-hardening` (draft #52) | Superseded | `main` re-landed the same outcomes with a different implementation: Keystore AES-GCM pairing tokens with forget-pair fencing in `PairedHostStorage`, backup and data-extraction exclusions, the off-main QR analyzer, and no debug-key release signing. #70/#71 carry the instrumented test and the off-UI-thread save. |
| `fix/android-session-ownership-races` (draft #53) | Needs a decision | It is written against eval's `SessionController` and `BrightnessOwnershipController`, which the stack does not have; the stack fences callbacks with `activeConnectionGeneration` instead. Whether brightness writes still race session teardown on the stack is **not yet verified**. |
| `design/appliance-lifecycle` = `codex/pr43-rejected-implementation` ⊃ `codex/complete-pr-43` (draft #43) | Not ported | The branch is named as a rejected implementation, and it depends on eval's `SessionController`. #72 covers the host-side session timeout; suspend/wake "appliance" behaviour is not implemented on the stack. |
| `codex/android-bridge-hardening` | Needs a decision | This is #52 and #53 (see above), plus separable repository tooling (a PR gate workflow, CodeQL, weekly stress/sanitizer jobs, Dependabot, Python repo-contract tests) and a Mac/Android connection-mode admission handshake that would change the wire protocol. Adding CI jobs and a protocol message are policy decisions, not integration fixes. |
| `eval/runtime-snapshot-2026-08-23` (includes `fix/adaptive-refresh-governor`) | Needs a decision | Missing from the stack: adaptive capture cadence (`AdaptiveRefreshController`, which overlaps #56 and the dirty-rect gate); Android `SessionController`, `PresentationController`, `FramePacer`, `ClockSync` (overlaps `ClockOffsetEstimator`) and `FrameTrace`; `AndroidColorProfile` (USB SDR calibration); `BrightnessOwnershipController`; `ScreenRecordingPermission` TCC diagnostics; the QualityLab and contention/smoothness lab scripts; and the evaluation receipts. Each needs to be ported deliberately onto the stack's architecture, not merged. |
| `stash@{1}` (control channel WIP on `feat/sgsr1-vsr`) | Superseded, except UDP | The TCP control channel landed as `ControlPortResolver` / `ControlChannel`. The UDP variant, an experiment against TCP-over-ADB-tunnel stalls, never landed anywhere and is kept only in the stash. |
