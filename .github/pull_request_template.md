## Description

Brief description of the changes in this PR.

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Documentation update
- [ ] Code refactoring
- [ ] Performance improvement

## Related Issue

Fixes #(issue number)

## Changes Made

- Change 1
- Change 2
- Change 3

## Testing

Check every state you actually reached. Leave the rest unchecked; a lower state
never implies a higher one.

- [ ] **Implemented** — builds locally in the dev checkout.
- [ ] **Unit-tested** — deterministic tests exercise the changed behavior and pass (`swift test`, `./gradlew testDebugUnitTest`).
- [ ] **CI-green** — hosted Android and macOS build/test/lint lanes pass at this exact head.
- [ ] **Installed** — the built artifact was installed on the target device.
- [ ] **Live-verified** — observed on the target Mac + tablet in a real session; say what was observed.
- [ ] **User-confirmed** — the reporting user says the symptom is gone in normal use.

Subsystem specifics, if they apply:

- [ ] macOS `[version]`
- [ ] Android `[device / version]`
- [ ] USB connection
- [ ] Wireless connection
- [ ] Streaming performance measured (before/after, not impression)

If a state is unchecked, say why in **Notes**. Hosted CI proves code contracts
only; it cannot prove CGVirtualDisplay, VideoToolbox, MediaCodec, panel
refresh, USB, brightness, or sleep/wake behavior on the target hardware.

## Screenshots (if applicable)

Required before merge for any UI, diagnostic-state, or hardware-recovery
change. Recovery work should show the failing state and the recovered state.
Name the device and app revision in the caption, and redact tokens, addresses,
and MAC identifiers.

- [ ] Screenshots attached for UI / state / recovery changes

## Checklist

- [ ] My code follows the project's coding standards
- [ ] I have not claimed a higher evidence state than I reached
- [ ] I have updated documentation if needed
- [ ] My changes don't introduce new warnings
- [ ] My changes don't add secret-bearing logs
- [ ] I have added comments for complex logic

## Additional Notes

Anything a reviewer needs to judge risk: what is still unverified, which claim
depends on target hardware, and what is out of scope.
