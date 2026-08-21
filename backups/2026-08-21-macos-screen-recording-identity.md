# macOS Screen Recording identity incident

Date: 2026-08-21
Scope: local development and private `exp/quality-fork` builds

## Symptom

SideScreen reported that Screen Recording was required even though macOS
displayed SideScreen as granted. Auto-start could also repeat the failure when
an old experiment copy or a rebuilt bundle was launched.

## Evidence captured

- The canonical installed bundle is `/Users/redacted/Applications/SideScreen.app`.
- Its bundle identifier is `com.sidescreen.app` and its designated requirement
  is `identifier "com.sidescreen.app" and info[CFBundleName] = "Side Screen"`.
- The current local build is ad-hoc signed with CDHash
  `941a12f86e2cd968fff08c02c2895e146ade9fb5`.
- The Screen Recording TCC row reported `auth_value=2` for
  `com.sidescreen.app`, but its stored code requirement contained the older
  CDHash `fff4f8fd83a298359fa17ae1365103ed0e69353a`.
- The old experiment bundle was archived at
  `/Users/redacted/vd_campaign/120hz_attack/exp_bin/SideScreenExp.app.legacy-20260821`
  so it cannot be confused with the canonical host. It was moved, not deleted.
- The current host logs its runtime bundle path and skips auto-start when the
  current bundle does not pass `CGPreflightScreenCaptureAccess()`.

The visible macOS grant was therefore for an older code identity, not for the
current rebuilt executable. A same-named app in another checkout can produce
the same symptom.

## Durable fix

1. `scripts/install_mac.sh` is the canonical local installer. It copies the
   current root build to `~/Applications/SideScreen.app`, signs it with the
   repository's stable local requirement, preserves the previous bundle as a
   timestamped `.previous.*` backup, and prints the installed identity.
2. `AppDelegate` logs the bundle identifier and path at launch and while
   checking permissions.
3. The ineffective `SideScreen_forceStart` auto-start bypass was removed.
   Auto-start now checks the current bundle's permission before starting the
   capture server, so a stale copy cannot create a misleading retry loop.
4. `README.md` contains the canonical build/install and stale-grant recovery
   procedure.

## Recovery procedure

From the canonical checkout:

```bash
./scripts/build_mac.sh
./scripts/install_mac.sh --launch
```

If the launched canonical bundle still reports Required, open System Settings
-> Privacy & Security -> Screen & System Audio Recording, remove the stale
Side Screen entry, and enable the exact `~/Applications/SideScreen.app` bundle
once. Then quit and relaunch that same bundle. Do not launch
`exp_bin/SideScreenExp.app`, a root build artifact, or a copy from another
checkout while diagnosing permissions.

Verify the identity before reporting a regression:

```bash
codesign -dvvv --verbose=4 ~/Applications/SideScreen.app 2>&1 | rg '^(Identifier|CDHash)='
codesign -d -r- ~/Applications/SideScreen.app 2>&1 | tail -4
```

Do not edit `/Library/Application Support/com.apple.TCC/TCC.db` directly and do
not add an automatic `tccutil reset` step. The user-facing System Settings
grant must be bound to the exact canonical bundle after the final build.

## Validation recorded with this incident

- `swift test --disable-sandbox`: 38 tests passed.
- `AndroidClient/gradlew testDebugUnitTest assembleDebug --no-daemon`: build
  succeeded; 45 actionable tasks, 1 executed and 44 up-to-date.
- `bash -n scripts/install_mac.sh scripts/build_mac.sh`: passed.
- `git diff --check`: passed.
- No GitHub Actions workflow files were added or run.

The code and documentation are committed separately from the final human
permission rebind: a macOS user must still approve the exact current bundle in
System Settings before live capture can be called verified.
