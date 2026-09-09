# Contributing to Side Screen

Thanks for helping improve Side Screen. This repository contains a macOS host, an Android client, protocol code, hardware-dependent display/codec paths, and a number of active experiments. The most useful contributions are small enough to review and explicit about what was actually tested.

Before starting substantial work, read [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md) and check the existing issues and pull requests. Several older draft PRs target evaluation branches and may overlap code that is already on `main`.

## Development requirements

### macOS

- macOS 13 Ventura or newer
- Swift 5.9+ / a compatible Xcode toolchain
- Screen Recording permission for runtime capture testing
- Accessibility permission for tablet-to-Mac input testing
- ADB for USB integration testing

### Android

- Android Studio or an equivalent Android SDK setup
- Java 11+; JDK 17 is recommended for current Android tooling
- Android SDK 34 for the current project configuration
- A real Android device for codec, panel-refresh, stylus, USB, brightness, and lifecycle validation

The Android application currently targets API 34 and supports API 26+.

## Clone and build

```bash
git clone https://github.com/tverma101/SideScreen.git
cd SideScreen
```

Build the macOS app bundle and DMG:

```bash
./scripts/build_mac.sh
```

Build the Android debug APK:

```bash
./scripts/build_android.sh
```

Run the platform test suites directly when working in a subsystem:

```bash
cd MacHost
swift test

cd ../AndroidClient
./gradlew testDebugUnitTest
```

Release Android builds require explicit signing credentials. Do not add debug-signing fallbacks, keystores, passwords, tokens, or other secrets to the repository.

## Repository layout

```text
SideScreen/
├── MacHost/                 macOS Swift host
│   ├── Sources/             application/runtime source
│   └── Tests/               Swift tests
├── AndroidClient/           Android Kotlin client
│   └── app/src/             main, test, and Android test sources
├── docs/                    architecture, validation, and experiment notes
├── scripts/                 build, install, benchmark, and maintenance tools
├── resources/               icons and screenshots
└── website/                 project website source
```

## Before changing code

1. Reproduce the problem on current `main` when possible.
2. Search existing issues and PRs for the same subsystem.
3. Separate a confirmed bug from a hypothesis about its cause.
4. For performance work, establish a measurable baseline before changing the hot path.
5. For protocol or lifecycle changes, write down the state/session invariant before implementation.

Do not revive an old experimental branch merely because its issue is still open. Compare it against current `main` first; preserve useful tests and acceptance criteria, not obsolete implementation.

## Change scope

Prefer focused pull requests. Avoid combining unrelated cleanup, protocol changes, renderer changes, and performance tuning in one diff.

Examples of good scopes:

- one reproducible settings bug plus its regression test;
- one Android ownership race plus concurrency coverage;
- one protocol parser rule plus compatibility tests;
- one documentation correction that removes a stale public claim;
- one performance experiment with a defined before/after measurement.

Large refactors should explain why the existing ownership boundary is insufficient and what new invariant the refactor establishes.

## Coding guidelines

### Swift

- Follow Swift API naming conventions.
- Prefer explicit ownership and lifecycle boundaries over hidden global state.
- Keep hot capture/encode/input paths allocation-conscious.
- Document private or unusual API assumptions next to the code that depends on them.
- Keep platform availability consistent with the macOS 13 deployment floor unless the requirement is intentionally raised.

### Kotlin

- Follow Kotlin conventions and prefer immutable state where practical.
- Keep network, decoder, UI, and session ownership clearly separated.
- Do not perform blocking network, storage, or crypto work on the Android main thread.
- Treat callbacks from an old connection/session generation as stale unless explicitly proven current.
- Use Android capability APIs rather than codec-name/device-name guesses when the platform exposes reliable capability data.

### General

- Make failures observable and actionable.
- Avoid silent fallbacks that change security, signing, resolution, refresh rate, or transport behavior.
- Avoid unbounded queues and unbounded packet/frame allocations.
- Keep comments focused on **why** a constraint exists.
- Do not claim latency, FPS, power, or quality improvements without evidence measuring the relevant boundary.

## Testing expectations

Different changes need different proof. A green hosted build is useful, but it cannot validate every Side Screen behavior.

### Usually suitable for deterministic tests

- parsers and framing;
- state machines;
- generation/session fencing;
- settings defaults and migrations;
- pacing/controller policy;
- math, timestamps, and bounded-allocation rules;
- pure decoder-selection policy.

### Requires real-device or real-Mac evidence

- CGVirtualDisplay behavior;
- ScreenCaptureKit runtime cadence;
- VideoToolbox hardware behavior;
- MediaCodec decoder throughput/recovery;
- actual Android panel refresh selection;
- USB/ADB interruption and reconnect;
- brightness ownership;
- lock/sleep/wake behavior;
- stylus hardware behavior;
- Wi‑Fi transport under real congestion.

If a PR changes one of these areas, include the exact hardware/OS versions and the test scenario. Performance PRs should include before/after measurements and visible behavior, not only averages from an internal stage.

## Pull requests

Use a descriptive branch name such as:

```text
fix/reset-refresh-default
fix/android-session-generation
perf/wireless-send-pressure
docs/repository-status
```

Commit messages should describe the behavior changed, for example:

```text
fix(mac): keep reset refresh default at 60 Hz
```

A useful PR description includes:

- the problem and reproduction;
- the root cause, when established;
- the behavioral change;
- tests run;
- hardware/runtime evidence where required;
- compatibility or migration impact;
- anything intentionally deferred.

Do not present an untested hardware hypothesis as a completed fix. If target-device validation is still missing, keep the PR draft or state the validation boundary explicitly.

## Bug reports

Please include:

- Side Screen version or commit SHA;
- Mac model and macOS version;
- Android device model and Android version;
- USB or wireless mode;
- configured refresh rate;
- exact reproduction steps;
- expected and actual behavior;
- logs or screenshots when relevant.

For performance reports, identify the symptom precisely: visible stutter, touch latency, decoder recovery, bandwidth, CPU/GPU load, WindowServer load, dropped frames, or connection delay. Avoid reducing different symptoms to a single “lag” number.

Do not post pairing secrets, signing credentials, private network credentials, or other sensitive information in public issues.

## Feature requests and experiments

For a feature request, describe the user problem before the implementation idea. For experiments, state the question being tested and the result that would cause the approach to be rejected.

Examples:

- “Does TCP head-of-line blocking dominate wireless p95 freshness after sender queues are bounded?”
- “Does the 120 Hz virtual display itself raise WindowServer CPU while capture is disabled?”

That makes experimental work useful even when the hypothesis is wrong.

## Documentation

Documentation should describe the behavior in the current repository, not inherited behavior that is no longer exposed. Preserve original contributor attribution and historical release notes where appropriate, while making fork-specific status and limitations clear.

## Review standard

A change is ready to merge when its scope is understandable, the relevant deterministic checks pass, required hardware behavior is verified, public documentation is accurate, and known limitations are stated rather than hidden.

Thank you for contributing.
