# SideTab project status

_Last reviewed: 2026-10-04 · repository version: 0.11.2 · `main` at `58f5050`_

This document is the short, maintained view of what is actually finished, what is still blocking a production-quality release, and which open issues are experiments rather than confirmed product bugs.

The GitHub issue tracker is intentionally detailed, but several issues were created against older evaluation branches. Before closing or implementing one, verify the report against the current `main` branch and preserve any hardware acceptance criteria that still matter.

## Current baseline

`main` is at `58f5050` (Sep 29). It contains the 0.11.2 S Pen/session-hardening
work plus the merged consolidation stack: rebrand and transport hardening (#75),
session-lifecycle timeout fixes (#72), tablet input source (#73), frame-timing
signposts (#74), settings runtime isolation (#76), and power-source-aware
Android refresh with idle teardown (#77).

Current user-facing baseline:

- macOS 13+ host and Android API 26+ client;
- fixed 1400×876 logical / 2800×1752 physical HiDPI display profile;
- 30, 60, 90, and 120 Hz refresh choices;
- 60 Hz normal startup default;
- USB via ADB reverse forwarding;
- wireless local-network mode with pairing;
- touch and S Pen input;
- HEVC plus H.264 fallback;
- paired-host secrets encrypted at rest on Android;
- release APK builds require explicit release-signing configuration.

The fork currently has no GitHub Release objects. Treat `VERSION` as the source version and `main` as development until a release/tag process is established.

## Fixed on `main`

### Reset Settings refresh default — #31

`DisplaySettings` now has one canonical default: `defaultRefreshRate = 60`, used both by fresh initialization and by `resetToDefaults()`. A regression test asserts reset returns to that same constant. This landed in `5d83719` (Sep 25) and is an ancestor of current `main`.

Issue #31 is still open in the tracker and is now a close/narrow candidate. Its original acceptance criteria (one source of truth for the refresh default) are satisfied on `main`; the remaining runtime-receipt expectation in that issue is not separately tracked as a release gate here.

## Production blockers

### 1. Session protocol and wireless security

Primary issues: #8, #12, #13, #34

The current tree has meaningful hardening already: paired-host credentials are encrypted at rest and wireless control traffic authenticates with the pairing token. The remaining architectural target is still a versioned session protocol with authenticated session binding and encrypted wireless transport.

**Release gate:** one logical session across video/control, bounded framing/parsing, stale-session rejection, authenticated channel replacement, and encrypted/pinned wireless transport without regressing USB.

### 2. Lock, sleep, wake, and reconnect lifecycle

Primary issues: #39, #40, #41, #42

The product should behave safely when the Mac locks or sleeps and should recover predictably when either device wakes. A locked Mac must not continue exposing fresh desktop pixels to an unattended tablet.

**Release gate:** deterministic state-machine tests plus real Mac/tablet lock, sleep, wake, reconnect, and explicit-disconnect torture runs.

### 3. Android runtime and ownership cleanup

Primary issues: #23, #24, #44, #45, #46, #47, #48, #49, #50, #51

Some fixes described by these issues have already landed on `main`, including pairing-secret storage hardening, release-signing discipline, scanner lifecycle changes, brightness/session fences, and session behavior improvements. The umbrella issues remain useful because they cover broader ownership and torture-test requirements.

**Release gate:** current-main audit first, then close or narrow stale sub-issues rather than re-implementing fixes from old snapshots. Remaining runtime ownership should have one authoritative session model and generation-safe cleanup.

### 4. Trustworthy performance evidence

Primary issues: #15, #16, #27, #28

Existing internal timestamps are useful for component debugging, but they are not all equivalent to capture-to-visible or glass-to-glass latency. Public performance claims should remain conservative until instrumentation measures the path being claimed.

**Release gate:** define timestamp boundaries, capture percentile distributions, track queue/decode/presentation freshness, and pair telemetry with visible real-device behavior.

## Performance and power investigations

These matter, but should not be confused with correctness blockers unless measurements prove a user-visible regression.

| Area | Tracking | Question |
| --- | --- | --- |
| 120 Hz / WindowServer cost | #3, #29, #30 | Is the cost from the virtual display mode, global input hooks, capture, or another component? |
| Idle CPU / bandwidth | #5, #19 | How close can static content get to idle without hurting wake responsiveness? |
| VideoToolbox latency | #14 | Which encoder properties materially improve real latency on supported macOS versions? |
| Android decoder policy | #17 | Are decoder selection/configuration decisions capability-driven on real target devices? |
| Transport evolution | #7, #21 | Does wireless tail latency actually justify moving beyond the current TCP design? |
| Capture alternatives | #6, #20 | Do alternative capture paths beat ScreenCaptureKit after quality, power, and compatibility are measured? |
| ADB lifecycle | #10, #78 | Can USB forwarding/recovery be made deterministic across disconnects and daemon restarts? #78/#79 add a manual repair path; the device-bound session manager in #10 is still open. |
| Touch hot path | #9 | Is there measurable input-path work left after current coalescing and logging fixes? |

## Live pull request map

Verified against GitHub on 2026-10-04. "Green CI" below means the existing
workflow runs passed; it is not hardware proof.

| PR | Head → base | State | CI | Notes |
| --- | --- | --- | --- | --- |
| #79 USB ADB crash recovery | `fix/usb-crash-recovery` → `main` | ready, mergeable | green (Oct 2) | Adds an honest `serverUnreachable` ADB state, a manual Repair USB Bridge action, and Android-side USB failure copy. Does **not** cover a tablet that stays `offline` in ADB after the repair. |
| #70 AndroidKeyStore instrumentation | `test/android-keystore-instrumentation` → `main` | ready, mergeable | green (Sep 9, stale) | Adds a device-test source set and an `assembleDebugAndroidTest` CI step. Hosted CI compiles these tests; it does not run Keystore behavior on hardware. |
| #71 Pairing save off UI thread | `fix/pairing-save-off-main` → `main` | ready, **conflicts with `main`** | green (Sep 9, stale) | Reproduced locally with `git merge-tree origin/main <head>`: real content conflict in `WirelessTabController.kt`. Needs a rebase onto `main` before it can be considered adoptable. |
| #56 Adaptive 120 FPS USB pacing | `adaptive-usb-fps` → `feat/android-power-policy` | ready, **base is obsolete** | green (Sep 29) | Its base head (`5cd523a`) already merged into `main` as #77, so the base branch is spent. `main` is not an ancestor of the head, so this still needs a fresh base. |
| #38, #43, #52, #53 | all → `eval/runtime-snapshot-2026-08-23` | drafts | none | Parallel-evolution drafts against a dead evaluation base, not patches against `main`. #52's outcomes largely landed via #64/#65/#68/#69. |

Closed without merge on 2026-09-09: #2, #32, #33, #36, #37, #54. They should
not appear in the active-PR map again.

### Proof requirement for #56

The adaptive 120 FPS branch is the largest remaining performance change, and
its own PR description is right to keep it unmerged until real-device tracing
exists. Hosted CI can validate controller logic, cadence math, GOP policy, and
API compatibility. It cannot show that the target Mac/tablet pair actually
sustains 120 Hz without unacceptable decode, transport, WindowServer, power,
or freshness cost. Keep that hardware requirement attached whenever #56 moves
to a fresh base.

### Proof requirement for #79

#79 has real-device screenshots committed alongside the change, which is
stronger than CI alone, but it is still unreviewed and unmerged. Until it
lands and is exercised on the reported failure, the current multi-day tablet
black-screen report stays **unverified** as a fixed problem. PR #79 fixes the
"ADB is wedged and nothing in the app can repair it" path; it explicitly does
not claim to fix a tablet that remains ADB-`offline`, and it does not deliver
automatic reconnect.

## Reliability branch validation

`codex/reliability-black-screen` is stacked on #79 and remains unmerged. It
adds finite Android decoder and USB resume budgets, independent socket write
deadlines, host session/capture generation fences, encoder replacement safety,
and rotation for long-running host logs. A live stream without a physical
ADB serial is labelled “Stream active” rather than claiming USB detection.

| Evidence state | Verified on 2026-10-04 |
| --- | --- |
| implemented | Integrated changes on the reliability branch; not released on `main`. |
| tested locally | 276 Swift tests and 159 Android unit tests pass; Android lint has zero errors and 12 existing warnings. Universal arm64/x86_64 host and debug APK build successfully. |
| installed | Current universal host and APK installed on the target Mac and Samsung SM-X800; previous artifacts preserved for rollback. |
| live-verified | Physical USB became ready after a targeted tablet-side ADB restart. Host Stop/Start caused three bounded client retries followed by real HEVC output and a visible desktop without another Connect tap. A longer host replacement exhausted four retries and returned to the connection/error UI; manual Connect restored video. |
| CI-green | Check the reliability PR's exact commit; local validation is not hosted CI. |
| user-confirmed | Pending. The approximately three-day recurrence and sleep/wake torture matrix still need validation. |

The initial physical USB transport stayed `offline` despite host-side and USB
gadget repairs. Restarting that tablet's ADB daemon in USB mode restored it.
This is a diagnostic recovery result, not evidence that the original cause of
the multi-day daemon failure has been eliminated. The app does not restart
ADB daemons automatically or change tablet debugging permissions.

## Recommended cleanup order

1. Review and land #79, then re-check the reported black screen on the target
   hardware before calling it fixed.
2. Rebase #71 onto `main` (or close it if the off-UI-thread save is no longer
   wanted) and land #70 so the pairing instrumentation is compiled in CI.
3. Move #56 to a fresh base off `main` when the adaptive work is actually
   revisited, and keep its hardware matrix as the merge gate.
4. Close the remaining eval-base drafts (#38, #43, #52, #53) or record an
   explicit porting decision for each, as already done for the rest.
5. Close or narrow #31 now that the refresh default is fixed on `main`.
6. Work the repository-tooling items tracked in #67; #54 is already closed.
7. Finish Protocol V2/security and lifecycle correctness before treating
   wireless as production-ready.
8. Publish a real release/tag only after version metadata, changelog, signed
   artifacts, and release notes all refer to the same commit.

## Version and release policy

For future releases:

- `VERSION` is the canonical application version.
- Android `versionName`/`versionCode` and macOS bundle versions must derive from or be checked against `VERSION`.
- `CHANGELOG.md` gets a dated section before the release is tagged.
- The tag, signed artifacts, release notes, and source tree must all identify the same version/commit.
- Do not advertise a GitHub release/download badge until this fork actually publishes GitHub Releases.
- Keep unreleased experimental performance work under `Unreleased` or in its PR until hardware validation is complete.

## Definition of “done”

Keep these evidence states separate. Reporting one as another is the most
common way a reliability claim becomes wrong:

| State | What it proves |
| --- | --- |
| implemented | The change exists in the tree. Nothing more. |
| unit-tested | Deterministic tests exercise the changed behavior and pass. |
| CI-green | The hosted Android and macOS build/test/lint lanes pass at this exact head. |
| installed | The built artifact was installed on the target device. |
| live-verified | Someone observed the behavior on the target Mac/tablet in a real session. |
| user-confirmed | The user reported the symptom is gone in normal use. |

Depending on the subsystem, completion can require unit/state-machine coverage,
protocol compatibility tests, target-device receipts for codec, display,
brightness, lifecycle, USB, or Wi-Fi behavior, before/after measurements for any
performance claim, and user-facing documentation that matches shipped behavior.

Hosted CI can prove many code contracts, but it cannot prove real
CGVirtualDisplay, VideoToolbox, MediaCodec, panel-refresh, USB, or sleep/wake
behavior on the target hardware.
