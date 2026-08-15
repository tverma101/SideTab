# SideScreen TCC permission repair (2026-08-15)

## Symptom

Launching the installed Mac host could leave the app unusable behind two
overlapping dialogs:

1. macOS asked SideScreen for Screen & System Audio Recording access.
2. SideScreen immediately attempted capture before that prompt was resolved.
3. ScreenCaptureKit returned `The user declined TCCs for application, window,
   display capture` and SideScreen placed a second modal error above the native
   prompt.

The privacy list could already show SideScreen as enabled while the rebuilt app
still failed preflight.

## Root causes

- The local `SideScreen_forceStart` preference bypassed the permission guard,
  called `CGRequestScreenCaptureAccess()`, and immediately started the server.
- Every build script used a plain ad-hoc signature. Its implicit designated
  requirement was the build's changing CDHash, so TCC could treat each rebuild
  as a different app even though `com.sidescreen.app` and the install path were
  unchanged.
- The permission check also called `SCShareableContent` during app launch on
  macOS 26, adding a potentially slow or hanging operation before the user had
  asked to start streaming.

## Repair

- Removed all force-start and `CGRequestScreenCaptureAccess()` paths.
- Made launch and periodic permission checks passive with
  `CGPreflightScreenCaptureAccess()`.
- Re-check permission when Start is requested and immediately before server
  construction.
- Route missing/declined/TCC/not-authorized failures to the existing inline
  permission card instead of presenting a second blocking `NSAlert`.
- Refresh preflight every two seconds so the Start button enables after the user
  returns from System Settings.
- Added `scripts/sign_mac_app.sh` and routed every Mac bundle build path through
  it. Local builds now embed this stable designated requirement:

  ```text
  designated => identifier "com.sidescreen.app" and info[CFBundleName] = "Side Screen"
  ```

  This is intentionally a local-development signature. A distributed release
  should use a real Apple Developer ID identity instead.
- Added the missing Screen Recording and Local Network usage descriptions to
  the legacy install script before signing.
- Deleted the machine's obsolete `SideScreen_forceStart` preference.

## Installed artifact and recovery

- Corrected bundle: `/Users/redacted/Applications/SideScreen.app`
- Previous installed bundle retained at:
  `/Users/redacted/Applications/SideScreen.pre-permission-fix-20260815.app`
- Earlier source/Android/settings baseline remains at commit
  `fc20cd9c94cf5008e616ae5956b3ec5d0495b61c` and tag
  `backup/2026-08-15-sharpness-paused`.

Because the previous approval was attached to an unstable CDHash requirement,
macOS may require one final off/on toggle for SideScreen in Privacy & Security.
After that one transition, the explicit requirement remains stable across local
rebuilds.

## Verification

- `swift test`: 35 tests passed, 0 failures.
- Universal arm64/x86_64 release build completed.
- `codesign --verify --deep --strict`: passed for the built and installed apps.
- `codesign -d -r-` reported the explicit requirement above.
- Installed app launched without a native capture prompt, force-start attempt,
  or overlapping error dialog.
- Live UI inspection showed one clean SideScreen window, an inline Screen &
  System Audio Recording card, and an Open System Settings recovery button.
