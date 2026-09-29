# Side Screen project status

_Last reviewed: 2026-09-09 · repository version: 0.11.2_

This document is the short, maintained view of what is actually finished, what is still blocking a production-quality release, and which open issues are experiments rather than confirmed product bugs.

The GitHub issue tracker is intentionally detailed, but several issues were created against older evaluation branches. Before closing or implementing one, verify the report against the current `main` branch and preserve any hardware acceptance criteria that still matter.

## Current baseline

`main` contains the 0.11.2 S Pen/session-hardening work plus additional unreleased performance, logging, wireless, and test changes.

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

## Confirmed bug on `main`

### Reset Settings changes the refresh default — #31

A fresh `DisplaySettings` instance falls back to **60 Hz**, while `resetToDefaults()` explicitly assigns **120 Hz**. Resetting settings therefore changes performance behavior instead of restoring the normal default.

**Desired fix:** define one canonical refresh default (60 Hz), use it for both initialization and reset, and keep 90/120 Hz as explicit user choices. Add a regression test that verifies both paths stay identical.

This is a small correctness fix and should be completed independently of adaptive-refresh experiments.

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
| ADB lifecycle | #10 | Can USB forwarding/recovery be made deterministic across disconnects and daemon restarts? |
| Touch hot path | #9 | Is there measurable input-path work left after current coalescing and logging fixes? |

## Active pull requests that need special handling

### PR #56 — adaptive 120 FPS USB pacing

This is the most substantial current performance branch. It adds adaptive active/idle pacing, pressure evidence, Android high-refresh intent, and decoder selection work. Its own PR description correctly keeps hardware proof as a merge gate.

Do not merge it merely because deterministic tests pass. The important unresolved question is whether the target Mac/tablet combination actually sustains the intended 120 Hz behavior without unacceptable decode, transport, WindowServer, power, or freshness regressions.

### Older draft/evaluation PRs

PRs #2, #32, #33, #36, #37, #38, #43, #52, #53, and #54 were created against experimental/evaluation bases or represent design-first slices. Several overlap changes already present on current `main`.

**Cleanup rule:** compare each draft against current `main` before reviving it. If its implementation is already superseded, close it with a short pointer to the landing commit or surviving issue. If its acceptance test is still valuable, preserve that test/issue rather than preserving stale code.

## Recommended cleanup order

1. Fix #31 so Reset Settings and fresh-init use the same 60 Hz constant.
2. Keep README/version/release metadata truthful to this fork; do not link fork badges or downloads to the upstream repository.
3. Triage older draft PRs against current `main` and close superseded implementation branches.
4. Audit #44's Android sub-issues against current main and rewrite them to only the work that remains.
5. Land or replace the CI/public-repo hardening from #54 on top of current `main` rather than its old eval base.
6. Finish Protocol V2/security and lifecycle correctness before treating wireless as production-ready.
7. Run the real-device acceptance matrix for PR #56 before merging adaptive 120 Hz behavior.
8. Publish a real release/tag only after version metadata, changelog, signed artifacts, and release notes all refer to the same commit.

## Version and release policy

For future releases:

- `VERSION` is the canonical application version.
- Android `versionName`/`versionCode` and macOS bundle versions must derive from or be checked against `VERSION`.
- `CHANGELOG.md` gets a dated section before the release is tagged.
- The tag, signed artifacts, release notes, and source tree must all identify the same version/commit.
- Do not advertise a GitHub release/download badge until this fork actually publishes GitHub Releases.
- Keep unreleased experimental performance work under `Unreleased` or in its PR until hardware validation is complete.

## Definition of “done”

A Side Screen change is not considered complete solely because it compiles. Depending on the subsystem, completion can require:

- deterministic unit/state-machine coverage;
- macOS and Android build/lint checks;
- protocol compatibility tests;
- target-device receipts for codec, display, brightness, lifecycle, USB, or Wi‑Fi behavior;
- before/after performance measurements when the change claims a performance improvement;
- user-facing documentation that matches the shipped behavior.

This distinction is intentional: hosted CI can prove many code contracts, but it cannot prove real CGVirtualDisplay, VideoToolbox, MediaCodec, panel-refresh, USB, or sleep/wake behavior on the target hardware.
