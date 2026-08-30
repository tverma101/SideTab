# SideScreen CI and test gates

SideScreen has two different classes of evidence. GitHub-hosted CI proves deterministic source/build behavior; real display behavior still requires the target Mac + Android tablet.

## Pull-request CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to the canonical branches.

- **Repository contracts (Ubuntu):** version/package identity, manifest export boundaries, Gradle wrapper integrity, workflow trigger/permission rules, Python tests, Python syntax, and shell syntax.
- **Android (Ubuntu/JDK 17):** `testDebugUnitTest`, `lintDebug`, and `assembleDebug`. Test/lint reports and a short-lived debug APK are uploaded as workflow artifacts.
- **macOS (macOS 14):** `swift test -c debug --parallel` and `swift build -c release` from the SwiftPM package.

The workflow uses read-only repository contents by default and deliberately does not use `pull_request_target`.

## Stress and sanitizers

`.github/workflows/stress.yml` runs weekly and can be started manually.

- Swift unit tests under Thread Sanitizer.
- The Android JVM suite five times with `--rerun-tasks` to expose race/flakiness that a single green run can hide.

This workflow is intentionally not on every commit because sanitizer/repeat jobs are substantially more expensive than the normal PR gate.

## Security automation

`.github/workflows/codeql.yml` analyzes both Swift and Java/Kotlin. Dependabot separately tracks GitHub Actions and Gradle dependencies.

## What hosted CI cannot prove

Do **not** treat GitHub Actions as a substitute for target-device receipts. The following remain local/hardware gates:

- CGVirtualDisplay actually appears and survives macOS lifecycle transitions.
- ScreenCaptureKit permissions and real WindowServer behavior.
- VideoToolbox hardware encoding latency/cadence under the target Mac.
- MediaCodec/Surface behavior on the SM-X800.
- Android screen-off/on, Activity/process death, brightness ownership, and real decoder resource counts.
- USB/ADB cable interruption and `adb reverse` behavior.
- Wi-Fi loss/route changes and cross-device reconnect behavior.
- Objective PixelCopy quality, camera-based cadence, and multi-hour streaming stability.

PRs that touch those areas should include the relevant local receipt in addition to green hosted CI.

## Suggested branch protection

Once the workflows have a successful baseline run, require these checks on the merge branch:

- `Repository contracts`
- `Android JVM + lint + APK`
- `macOS Swift tests + release build`

CodeQL can also be required once its first Swift and Java/Kotlin scans complete successfully. Keep the weekly stress workflow advisory unless it proves stable enough to promote to a merge gate.
