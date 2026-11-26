# Repository consolidation

Updated 2026-10-05. Re-verified against GitHub (`origin/main` = `544cd63`).

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

## Local work integration (re-verified 2026-10-05)

Every branch and stash that existed only locally was either landed on the SideTab stack or given an explicit decision below. **Nothing was deleted.** Each branch is still on `origin` and both stashes are intact, so any of the no-fit items can be revisited.

The previous integration stack is now fully merged. `origin/main` is at
`544cd63` and includes the product/runtime work in #75, #72, #73, #74, #76,
#77, plus Android recovery and pairing changes in #79, #70, #80, #56, and #71.
The local integration branch started from that exact clean commit; its initial
tracked and untracked worktree was clean.

What is still open on top of `main`:

- #53 `fix/android-session-ownership-races` (draft; stale eval base).
- #43 `design/appliance-lifecycle` (draft; stale eval base).
- #38 `exp/wireless-60fps-freshness` (draft; stale eval base).

The Android session-generation and brightness-write race from #53 was verified
against current code and adapted on the local AirPlay integration branch using
one shared generation fence. Adversarial review identified a check/use gap in
frame delivery and display-size callbacks; those effects are now inside the
fence, and local Android unit tests and lint pass. Its generic SessionController
rewrite remains unported because this runtime uses a different session model. #38's freshness
policy is already present in evolved form on `main`; #43 remains a policy
proposal with no runtime hooks. No open PR was merged or changed during this
integration.

### Landed

| Source | Where | Notes |
|---|---|---|
| `wired-cpu` branch (5 commits) | #76 | Runtime and metrics state split out of `DisplaySettings`, so ticks no longer relayout the settings form. |
| `codex/power-policy-wip-20260928` | #77 | Power-source-aware refresh and screen-off idle teardown. The WIP's decoder operating-rate change was not taken; see #77. |
| PR #56 `adaptive-usb-fps` | #56, was retargeted onto #77, which has since merged | Its base branch is now redundant. If the adaptive work is revived it must be re-based on `main`; integration decisions are recorded at the top of `docs/adaptive-usb-fps.md`. |
| `stash@{0}` (crash fixes, 2026-08-15) | #75 | `showError` guard ported. Its slider-snap half was already covered by `PreferencesManager.snapToStep`. |

### Not ported, with reasons

The August line forks from `4467484` (2026-08-21). `eval/runtime-snapshot-2026-08-23` is its base: 52 commits, which include all of `fix/adaptive-refresh-governor`. It is **a parallel evolution of the codebase, not a patch set.** Measured against the stack top, `MainActivity` differs by about 2,400 changed lines and `StreamClient` by about 1,800. It adds whole subsystems the stack does not have, several of which compete with designs the stack has since landed.

| Branch | Decision | Reason |
|---|---|---|
| `exp/wireless-60fps-freshness` (draft #38) | Superseded | `WirelessFreshnessPolicy` is on both sides of the stack in an evolved form; see `docs/wireless-60fps.md`. |
| `fix/android-foundation-hardening` (closed draft #52) | Superseded | `main` re-landed the same outcomes with a different implementation: Keystore AES-GCM pairing tokens with forget-pair fencing in `PairedHostStorage` (#64), backup and data-extraction exclusions, the off-main QR analyzer (#68), no debug-key release signing, fail-closed legacy migration (#69), and Android lint in CI (#65). The instrumented test (#70) and off-UI-thread pairing save (#71) are also merged. |
| `fix/android-session-ownership-races` (draft #53) | Narrow fix adapted; rest deferred | Current Android now serializes generation changes, client retirement/publication, and brightness side effects through a tested fence. The larger eval-only `SessionController` and publication queue are not imported. |
| `design/appliance-lifecycle` (draft #43) | Deferred | It defines useful lifecycle policy but its own PR description says it is not connected to Mac power notifications, ScreenCaptureKit, Android decoder ownership, or reconnect. It depends on eval's `SessionController`; no live lifecycle changes were imported. |
| `codex/android-bridge-hardening` | Split; tooling re-homed | This is #52 and #53 (see above) plus a Mac/Android connection-mode admission handshake that would change the wire protocol. The repository-tooling half (a PR gate workflow, CodeQL, weekly stress/sanitizer jobs, Dependabot, repo-contract tests) was already re-homed into issue #67 when the old all-in-one PR #54 was closed unmerged on 2026-09-09. The protocol handshake remains undecided. |
| `eval/runtime-snapshot-2026-08-23` (includes `fix/adaptive-refresh-governor`) | Needs a decision | The code halves to port deliberately are the Android `SessionController` / `PresentationController` / `FramePacer` / `FrameTrace` grouping, `BrightnessOwnershipController`, `ScreenRecordingPermission` TCC diagnostics, and the QualityLab and contention/smoothness lab scripts. The transport-overlap items (adaptive capture cadence vs #56 and the dirty-rect gate, `ClockSync` vs `ClockOffsetEstimator`) are already covered by evolved versions on `main` and should not be re-ported. The evaluation receipts remain as historical evidence only. |
| `stash@{1}` (control channel WIP on `feat/sgsr1-vsr`) | Superseded, except UDP | The TCP control channel landed as `ControlPortResolver` / `ControlChannel`. The UDP variant, an experiment against TCP-over-ADB-tunnel stalls, never landed anywhere and is kept only in the stash. |
