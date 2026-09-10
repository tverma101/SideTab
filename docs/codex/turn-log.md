# Codex turn log

## 2026-09-05 — Public-readiness location audit and Actions setup

- `scope`: Android manifest and source, macOS source and entitlements, GitHub Actions workflows, and all fetched remote branch tips
- `changed`: `README.md`, `PRIVACY.md`, `docs/codex/turn-log.md`, and Swift call-site compatibility fixes in `MacHost/Sources/AppDelegate.swift`, `MacHost/Sources/ControlPortResolver.swift`, `MacHost/Sources/StreamingServer.swift`, and `MacHost/Tests/SideScreenTests/PairingURLTests.swift`
- `validation`: static location scan found zero location permissions, APIs, filenames, or coordinate data; workflows use hosted `ubuntu-latest`/`macos-14`, `contents: read`, and no location access or upload step; local `swift test --package-path MacHost` passed 52 tests; hosted Android run `33989543211` and hosted macOS run `33989543209` passed; repository Actions runner inventory was empty (`total_count: 0`)
- `evidence`: implemented, tested, and live; final visibility is public, anonymous GitHub API access returned HTTP 200, `PRIVACY.md` returned HTTP 200, and the repository runner inventory remains empty (`total_count: 0`)
- `blocker`: none for the requested publication gate; this is not a legal opinion and third-party dependency terms remain their respective responsibility
- `next`: keep future workflows on hosted runners and rerun the location audit before materially expanding telemetry or permissions
- `rollout_refs`: current Codex session

## 2026-09-07 — Wireless 60 FPS transport and native Android path

- `scope`: local Mac wireless sender, Android wireless receiver, reconnect state, native presentation path, and public-readiness audit
- `changed`: added shared wireless freshness/session policies; capped wireless capture/encode sessions at 60 FPS and 40 Mbps average/60 Mbps one-second peak; added byte-aware, generation-fenced sender pressure; enlarged the wireless Android socket/input buffers; added native SurfaceView decoder targeting, stale-output release, and policy tests; updated `README.md`, made `docs/wireless-60fps.md` explicitly trackable, and ignored local APK recovery backups in `.gitignore`
- `files`: `MacHost/Sources/AppDelegate.swift`, `ScreenCapture.swift`, `StreamingServer.swift`, `VideoEncoder.swift`, `WirelessFreshnessPolicy.swift`, `WirelessSessionProfile.swift`, `WirelessTransportPressure.swift`, their wireless tests, `AndroidClient/app/src/main/java/com/sidescreen/app/MainActivity.kt`, `StreamClient.kt`, `VideoDecoder.kt`, the Android wireless policy/profile, and the Android policy test
- `validation`: `swift test --package-path MacHost` passed 57 tests; `(cd AndroidClient && ./gradlew testDebugUnitTest --no-daemon)` passed 27 tasks/tests; `git diff --check` passed; `./scripts/build_mac.sh` produced a valid signed universal `SideScreen.app` and DMG; `./scripts/build_android.sh` and `./scripts/install_android.sh` produced and installed the debug APK, with recovery artifacts under `backups/apk/20260907T232317Z`; the rebuilt artifacts completed a live wireless handshake on SM-X800, native `c2.qti.hevc.decoder` decode at a 60 Hz target, SurfaceView presentation, touch control, zero decoder drops in sampled windows, and approximately 11–12 ms average decode latency; a bounded animated virtual-display probe rendered correctly but the host's observed changed-frame rate remained approximately 18–24 FPS
- `public_readiness`: repository landing page returned HTTP 200; tracked-file audit found no high-confidence private-key/provider-token markers or sensitive certificate/key filenames; public-facing README, privacy, contribution, license, issue-template, and workflow files are present; no remote branch, PR, merge, workflow, or Actions state was changed
- `evidence`: implemented, tested, packaged, installed, live handshake/native decode, and public HTTP reachability are proven; user-confirmed acceptance is not recorded; the configured 60 FPS ceiling and decoder target are proven, but sustained 60 FPS under a moving real application remains unproven because this host's virtual-display capture probe delivered fewer changed frames
- `blocker`: no implementation/test blocker; remaining performance evidence requires a moving workload that the host virtual-display path actually emits at 60 FPS, plus a longer two-device measurement of sender/receiver FPS, bitrate, stale drops, reconnect, and thermals
- `cleanup`: stopped the rebuilt host, stopped the Android test package, restored the pre-test Mac USB connection preference, moved temporary screenshots/probe logs to Trash, and retained the APK recovery backup; no listeners remain on ports 54321/54322
- `next`: run the same artifact on a representative moving desktop/video workload and capture a sustained 60-FPS trace before claiming full 60-FPS user acceptance
- `rollout_refs`: current Codex session

## 2026-09-07 — macOS duplicate app cleanup and single-install lifecycle

- `scope`: macOS SideScreen app bundles in the user install directory, build/run entrypoints, and the developer install path
- `changed`: added `scripts/cleanup_old_app_copies.sh` with dry-run/apply modes and bundle-ID validation; added `scripts/install_mac.sh` to replace the exact user-facing bundle without creating backups; wired cleanup into `scripts/build_mac.sh` and `scripts/run.sh`; added the canonical `script/build_and_run.sh` and `.codex/environments/environment.toml`; documented the single-copy behavior in `README.md`
- `validation`: pre-cleanup inventory found 45 `~/Applications/SideScreen.app.previous.<timestamp>` bundles, all `com.sidescreen.app` version 0.11.1 and none running; the helper dry-run selected exactly those 45; `--apply` moved all 45 to macOS Trash; post-cleanup `~/Applications` contains only `SideScreen.app`; the new installer replaced that target twice with signed version 0.11.2 and created zero new snapshots; `script/build_and_run.sh --verify` built the universal app, signed it, launched it as a bundle, and verified the process; a controlled snapshot was removed automatically by the normal `scripts/run.sh` path; `bash -n`, ShellCheck, and `git diff --check` passed
- `evidence`: implemented, tested, installed, and locally live launch verification are proven; the old copies are recoverable in Trash; user-confirmed visual acceptance is not recorded; source and app bundles in separate historical workspaces were not removed because they are outside the bounded user install cleanup
- `blocker`: none for the requested macOS install-directory cleanup; Trash was intentionally not emptied
- `cleanup`: stopped the temporary verification launch; no SideScreen process or listeners remain; preserved the current user install and repository build artifacts; no unrelated apps or source worktrees were changed
- `git`: local topic branch only, no push, merge, PR, workflow, or Actions mutation
- `next`: use `./scripts/install_mac.sh --launch` or `./script/build_and_run.sh`; do not invoke the historical installer in an old worktree, since only the canonical repository path now performs backup-free replacement
- `rollout_refs`: current Codex session

## 2026-09-07 — Wired SDR color-range alignment

- `scope`: macOS wired ScreenCaptureKit/CGDisplayStream SDR capture, Android hardware-decoder range signaling, and the installed USB path
- `changed`: made 8-bit video-range `420v` the normal capture format; retained legacy `SideScreen_exp_pixelFormat=8bit` as an explicit full-range A/B control; made the CGDisplayStream fallback follow the selected 8-bit range; taught `PatternInjector` to encode luma/chroma in the destination range; added `VideoColorProfile` tests; updated `README.md` and `CHANGELOG.md`
- `files`: `MacHost/Sources/VideoColorProfile.swift`, `MacHost/Sources/ScreenCapture.swift`, `MacHost/Sources/PatternInjector.swift`, `MacHost/Tests/SideScreenTests/VideoColorProfileTests.swift`, `README.md`, `CHANGELOG.md`
- `validation`: local Swift suite passed 61 tests with 0 failures; `git diff --check` passed; `./scripts/build_mac.sh` produced the signed universal app and DMG; `./scripts/install_mac.sh --launch` installed version 0.11.2 with valid code signing and created 0 app snapshots; the installed sender logged `Stream color profile: 8-bit video`; the connected SM-X800 reported Android decoder `color-range=2 (limited)`, zero decode drops, and repeated frame milestones at the expected 60 Hz receiver cadence with approximately 9–12 ms decode latency
- `evidence`: implemented, tested, packaged, installed, and live wired range/decoder behavior are proven; visual user-confirmed color acceptance is not recorded; sustained wireless 60 FPS remains separately bounded by the prior live evidence
- `blocker`: none for the range implementation; user visual confirmation is still the final acceptance boundary for the reported color symptom
- `cleanup`: temporary auto-start was restored/deleted after validation, and the connected Mac/Android test session plus ADB reverse mappings will be stopped/removed before handoff; the single installed app remains in `~/Applications`, and prior duplicate bundles remain recoverable in Trash
- `git`: local topic branch only, no push, merge, PR, workflow, or Actions mutation
- `next`: visually recheck a representative wired desktop with the installed build; if colors remain wrong, capture paired PixelCopy measurements with default `420v` and explicit `420f` to distinguish a remaining display profile issue from range expansion
- `learning_checkpoint`: `promoted`: source contract plus same-device A/B evidence and current live logs support the limited-range wired SDR fix; `quarantined`: none; `deprecated`: full-range as the normal SDR default; `skipped`: global memory update
- `rollout_refs`: current Codex session

## 2026-09-07 — Topic branch publication

- `scope`: Git publication of the SideScreen Android and macOS work from the canonical checkout
- `changed`: pushed commits `edb14aa`, `66ede46`, and `d468d1a` from `codex/wireless-60fps-native` to `origin/codex/wireless-60fps-native`; no default branch, PR, merge, workflow, or Actions state changed
- `validation`: clean worktree before push; remote accepted the new branch; the remote branch points at `d468d1a`; the published range contains both `AndroidClient` and `MacHost` paths
- `evidence`: source changes, tests, packaging, installation, and live evidence remain documented in the preceding entries; branch publication is proven; user-confirmed acceptance is not recorded
- `blocker`: none for the requested topic-branch push
- `next`: review or open a PR from the published topic branch if desired; default-branch integration remains separately authorized work
- `learning_checkpoint`: `promoted`: scoped topic-branch publication after a clean audited baseline; `quarantined`: none; `skipped`: default-branch integration and Actions
- `rollout_refs`: current Codex session

## 2026-09-07 — Local-work coverage audit

- `scope`: canonical checkout, all registered SideScreen worktrees, local branches, stashes, and ignored generated artifacts after publishing `codex/wireless-60fps-native`
- `changed`: no source changes; this audit record is the only repository update
- `validation`: canonical worktree is clean with local `HEAD` equal to `origin/codex/wireless-60fps-native`; the published branch contains the Android and Mac changes; the remote S Pen branch history is already an ancestor; `codex/android-bridge-hardening` at `64dd35c` has no remote containing its tip; two stashes retain Android/Mac files; a separate S Pen worktree has only untracked `.project-memory` metadata; ignored APK/build/DMG/app artifacts remain local
- `evidence`: requested branch fully committed and pushed; separate local-only branch, stashes, ignored build/recovery outputs, and a prunable stale detached worktree are not part of that push; no local-only branch or stash was deleted or published
- `blocker`: none for the requested branch; integrating or publishing the separate bridge-hardening branch would require a distinct scope decision
- `cleanup`: no destructive cleanup performed; stale worktree was only identified with `git worktree prune --dry-run`; ignored artifacts and stashes were preserved
- `git`: current topic branch remains the only branch changed/published for this request; no PR, merge, default-branch, workflow, or Actions mutation
- `next`: if broader publication is desired, review `codex/android-bridge-hardening` and the two stashes independently before pushing; generated APK/DMG/app outputs should remain release artifacts rather than Git source
- `learning_checkpoint`: `promoted`: clean/pushed topic branch is distinct from other local refs and generated outputs; `quarantined`: bridge-hardening branch and stashes pending scope review; `skipped`: destructive cleanup and unrelated branch publication
- `rollout_refs`: current Codex session

## 2026-09-08 — Recoverable macOS artifact consolidation

- `scope`: SideScreen macOS app bundles, legacy installer snapshots, and all discovered SideScreen DMGs across the canonical and historical local worktrees
- `changed`: no product source; created `/Users/tejas/Documents/SideScreen-Backups.noindex/20260908T170622Z`; copied all five discovered DMGs with source-qualified names; backed up the installed and canonical 0.11.2 bundles; moved the last-used Design-worktree 0.11.2 bundle and the historical PR43 0.11.1 bundle into the backup; moved 46 legacy `SideScreen.app.previous.*` bundles out of `~/.Trash` into the backup
- `validation`: every DMG backup matched its source SHA-256 and passed `hdiutil verify`; all four preserved app bundles passed deep code-signature verification; the installed `/Users/tejas/Applications/SideScreen.app` remains version 0.11.2 and valid; `SideScreen_refreshRate=120`; the cleanup helper dry-run found zero stale snapshots; the exact Spotlight app-bundle query returned only the user install; no SideScreen process was running
- `evidence`: recoverable backup and filesystem cleanup are proven; the installed artifact and configured 120-FPS wired target are preserved; no new stream or visual acceptance run was performed, so live sustained 120-FPS behavior and user-confirmed visual acceptance remain separate evidence states
- `blocker`: none for duplicate cleanup or artifact preservation; the backup directory is intentionally retained and the macOS Trash was not emptied globally
- `cleanup`: `~/Applications` contains one user-facing SideScreen.app; historical generated app bundles are absent from their two non-canonical worktrees; no source checkout, branch, stash, or unrelated Trash item was removed
- `git`: documentation-only turn record; no default-branch, PR, workflow, or Actions mutation
- `next`: keep using the canonical `scripts/install_mac.sh`/`scripts/run.sh` lifecycle; remeasure wired 120-FPS visual behavior only with the representative Android device/workload, not from artifact identity alone
- `learning_checkpoint`: `promoted`: backup-before-consolidation plus exact-install-root cleanup preserves the known-good artifact while removing active duplicates; `quarantined`: none; `deprecated`: none; `skipped`: global memory update and destructive Trash emptying
- `rollout_refs`: current Codex session

## 2026-09-08 — Compact macOS UI preserved after design review

- `scope`: macOS settings surface review with the user's efficiency and connection priorities
- `changed`: no product source change retained; evaluated a temporary native split-view redesign, then reverted `MacHost/Sources/SettingsWindow.swift` and removed `MacHost/Sources/ModernSettingsView.swift` after live inspection and user feedback; preserved the existing app/DMG backup set
- `validation`: the temporary redesign passed `swift test --package-path MacHost` with 61 tests; `git diff --check` passed after the revert; `./scripts/build_mac.sh` and `./scripts/install_mac.sh --launch` rebuilt and installed the compact UI; the installed app passed deep code-signature verification; live macOS accessibility inspection showed the original compact 480×780 single-scroll surface; `SideScreen_connectionMode=usb` and `SideScreen_refreshRate=120` remained intact
- `evidence`: compact UI restoration is implemented, installed, and live-verified; the user's preference for the compact layout is recorded; no sustained wireless 60-FPS or wired visual remeasurement was performed in this design-review turn
- `blocker`: broad macOS layout redesign is paused; the next change must preserve the compact window and improve connection/readiness efficiency incrementally
- `cleanup`: stopped the rejected redesign build before reinstalling the compact app; no source checkout, branch, backup, DMG, or unrelated app was removed; the rejected temporary file is absent and the worktree is clean before this documentation entry
- `git`: documentation-only follow-up; no default-branch, PR, workflow, or Actions mutation
- `next`: target the existing compact surface with small connection-first improvements such as clearer readiness state, lower-friction start/reconnect behavior, and efficient performance feedback without replacing the layout
- `learning_checkpoint`: `promoted`: compact, incremental macOS changes fit the user's stated efficiency/connection goal; `quarantined`: the temporary split-view redesign; `skipped`: global memory update and another broad visual redesign
- `rollout_refs`: current Codex session

## 2026-09-08 — Revert UX experiment and optimize backend hot paths

- `scope`: restore the compact macOS settings surface and improve macOS connection/capture efficiency without changing UX
- `changed`: reverted the extra connection-status/second-Start UI from `6b5f8b9` in `e67b2ed`; moved ADB/path/process status probes off the main actor; prevented overlapping USB status probes and self-healing ADB repairs; made cached ADB path reads thread-safe; latched per-session capture flags so the frame callback avoids repeated connection-mode and experiment-preference reads; documented the backend work in `CHANGELOG.md`
- `validation`: `git diff --check` passed; `swift test --package-path MacHost` passed 61 tests with 0 failures; `./scripts/build_mac.sh` produced a signed universal app and DMG; `./scripts/install_mac.sh --launch` installed the backend build with valid deep code signing and created 0 snapshots; live accessibility inspection showed the original compact single-scroll window with exactly one Start button; the app remains configured for USB and 120 Hz
- `evidence`: UX reversion, backend source implementation, tests, packaging, installation, and live compact UI state are proven; no tablet stream was started during this backend-only turn, so no new sustained wireless FPS or reconnect trace is claimed
- `blocker`: none for the backend changes; real-device connection/reconnect and sustained wireless performance still need a representative Android workload
- `cleanup`: retained the existing recoverable app/DMG backup; no duplicate app snapshot was created; no source checkout, branch, device, display session, or unrelated app was removed
- `git`: local revert plus backend-only follow-up is ready for the already-authorized `codex/wireless-60fps-native` topic branch; no default-branch, PR, workflow, or Actions mutation
- `next`: measure the installed backend with the Android device under USB and wireless reconnect/motion workloads, keeping the compact UI unchanged
- `learning_checkpoint`: `promoted`: backend efficiency changes must stay below the UI boundary; `quarantined`: second-Start/status-strip experiment; `skipped`: broad UI redesign, global memory update, and a new live stream run
- `rollout_refs`: current Codex session

## 2026-09-08 — Harden Android decoder handoff and fresh APK installs

- `scope`: Android frame-delivery lifecycle, asynchronous `MediaCodec` input handoff, and the local APK install pipeline; macOS UI unchanged
- `changed`: generation-tagged Android decoder input-buffer callbacks reject retired-codec indices; decoder publication is visible to the socket thread; a frame arriving before decoder startup releases safely and requests a throttled sync frame; `scripts/install_android.sh` now rebuilds the debug APK by default with an explicit `--skip-build` escape hatch; updated `README.md` and `CHANGELOG.md`
- `validation`: `(cd AndroidClient && ./gradlew --no-daemon testDebugUnitTest assembleDebug)` passed; `swift test --package-path MacHost` passed 61 tests with 0 failures; `git diff --check` and `bash -n scripts/install_android.sh scripts/build_android.sh scripts/backup_android_apks.sh` passed; the fresh debug APK was generated at `AndroidClient/app/build/outputs/apk/debug/app-debug.apk`, verified with Android SDK `apksigner` v2, and identified as package `com.sidescreen.app` version `0.11.2`; the installer correctly exits without mutation when ADB has no device
- `evidence`: Android source implementation and JVM/build validation are proven; no APK installation or live USB/wireless stream run was possible in this turn because `adb devices -l` returned no connected device; sustained 60-FPS and user-confirmed Android acceptance remain unproven
- `blocker`: reconnect the representative SM-X800 (or another Android target) over ADB for install, handshake, decoder, reconnect, and sustained-motion validation
- `cleanup`: no device, app package, reverse mapping, Mac stream, backup, or unrelated file was changed; existing APK recovery backups remain preserved
- `git`: Android source, installer, README, changelog, and this turn record are local changes on `codex/wireless-60fps-native`; topic-branch publication remains authorized, but will follow final audit
- `next`: with the tablet connected, run `./scripts/install_android.sh`, capture `adb logcat` plus host logs, verify first-frame startup and reconnect, then measure a moving workload at the native 60-FPS wireless target
- `learning_checkpoint`: `promoted`: asynchronous decoder lifecycle must fence callback state by codec generation; `quarantined`: the exact user-reported runtime failure cause until a device trace is captured; `skipped`: global memory update and broad UI work
- `rollout_refs`: current Codex session

## 2026-09-08 — Deterministic ADB pipeline and plugged-in USB diagnosis

- `scope`: Mac ADB selection, Android install/reverse helpers, and the installed SideScreen host; compact macOS UI unchanged
- `changed`: added `scripts/resolve_adb.sh`; updated Android install/setup/dev/run/backup helpers to use one selected ADB binary and serial, prefer Android SDK platform-tools, preserve the no-device fast exit, and print full ADB state; made `StatusDetector` and `AppDelegate.setupADBReverse()` use the same SDK-first resolver; updated `README.md`, `CHANGELOG.md`, and the USB checklist hint
- `files`: `scripts/resolve_adb.sh`, `scripts/install_android.sh`, `scripts/setup-usb.sh`, `scripts/backup_android_apks.sh`, `scripts/install.sh`, `scripts/run.sh`, `scripts/dev-test.sh`, `MacHost/Sources/StatusDetector.swift`, `MacHost/Sources/AppDelegate.swift`, `MacHost/Sources/SettingsWindow.swift`, `README.md`, and `CHANGELOG.md`
- `validation`: `bash -n` passed for all changed shell helpers; resolver selected `/Users/tejas/Library/Android/sdk/platform-tools/adb` and honored the explicit Homebrew override; `git diff --check` passed; `swift test --package-path MacHost` passed 61 tests; Android `testDebugUnitTest` passed; `scripts/build_mac.sh` produced a signed universal app and DMG; `scripts/install_mac.sh --launch` installed the refreshed host at `/Users/tejas/Applications/SideScreen.app` and created 0 stale snapshots; the fresh installer now reports its selected ADB path and exits before build/backup when no device is ready
- `evidence`: source implementation, tests, packaging, and installed Mac host are proven; live ADB server path is proven to be SDK platform-tools; live USB device/stream installation remains unproven because SDK ADB returns an empty device list and macOS IOUSB enumerates only the existing hub/receiver/adapter/storage devices, with no Samsung/Android vendor/product entry
- `blocker`: the tablet is not reaching macOS as a USB data/ADB device; unlock it, choose a data-capable USB mode, accept the USB debugging prompt, or replace the cable/port if no Samsung/Android entry appears; no SideScreen code can install or reverse-forward until macOS enumerates the target
- `cleanup`: preserved the replaced installed app at `/Users/tejas/Documents/SideScreen-Backups.noindex/20260908T172500Z/installed-app/SideScreen.app`; kept the existing DMG/app recovery set; no duplicate UI bundle was created; no Trash was emptied
- `git`: source and documentation changes are ready for the already-authorized `codex/wireless-60fps-native` topic branch; no default-branch, PR, workflow, or Actions mutation
- `next`: after the tablet appears in `adb devices -l` as `device`, run `./scripts/install_android.sh`, verify `adb reverse` ports `54321/54322`, then capture Android logcat and a wired first-frame/reconnect trace before claiming the live Android path is fixed
- `learning_checkpoint`: `promoted`: one SDK-first ADB resolver must be shared by Mac discovery, reverse setup, and Android installers; `quarantined`: the exact physical connection fault until the tablet enumerates; `skipped`: UI redesign, broad cleanup, and global memory update
- `rollout_refs`: current Codex session

## 2026-09-08 — Live wired APK install and first-frame verification

- `scope`: representative SM-X800 USB install, ADB reverse tunnel, Mac host startup, Android first-frame decode, and current wired stability
- `changed`: no product source change; installed the current debug APK through the repaired SDK-first ADB pipeline and captured live evidence after the tablet reappeared on USB
- `validation`: ADB reported `R52X30G5TNB` as `device` / `SM_X800`; macOS enumerated `SAMSUNG_Android`; `./scripts/install_android.sh` rebuilt and installed version `0.11.2` with APK SHA-256 `535913fd2ded8da591d4d25ac89ea98ee7d4bcfad3f64dd743a7e89ef6f865a6`; reverse mappings `54321` and `54322` were active; the installed Android client connected to `127.0.0.1:54321`; the Mac host listened on both ports; `c2.qti.hevc.decoder` rendered `2800x1752` at a `120 Hz` target with limited color range; a direct tablet screenshot showed the streamed Mac desktop; a sustained sample reached 1,860 received / 1,859 decoded frames with zero drops and zero input-buffer timeouts, approximately 9–10 ms average decoder latency, and low-millisecond control RTTs
- `evidence`: APK installation, USB reverse forwarding, Mac listener, Android handshake, first decoded frame, native 120-Hz decoder selection, rendered desktop, and sustained wired stability are live-proven; user-confirmed visual color acceptance remains separate
- `blocker`: none for the current wired connection path; remaining acceptance is the user's visual confirmation of color/appearance under their normal desktop workload and a separate longer workload-specific FPS measurement if needed
- `cleanup`: retained the new APK backup at `/Users/tejas/Projects/SideScreen/backups/apk/20260908T213430Z`; left the validated wired stream running; no source checkout or backup artifact was removed
- `git`: documentation-only evidence update on the already-published `codex/wireless-60fps-native` branch; no default-branch, PR, workflow, or Actions mutation
- `next`: visually confirm the streamed wired desktop/colors; if the user reports a remaining mismatch, capture paired host/tablet pixel samples while this same live path is connected
- `learning_checkpoint`: `promoted`: the prior no-device state was an external USB enumeration condition, and the repaired SDK-first pipeline installs/forwards correctly once the device appears; `quarantined`: none; `skipped`: UI redesign and global memory update
- `rollout_refs`: current Codex session

## 2026-09-08 — Restore menu-bar tablet brightness control

- `scope`: compact macOS status-item menu, Android BRIGHT control path, and installed wired session
- `changed`: restored the compact AppKit Tablet Brightness slider in `MacHost/Sources/BrightnessMenuItemView.swift`; added persisted host-side level handling in `MacHost/Sources/NativeBrightnessController.swift`; reconnected the slider and reconnect replay in `MacHost/Sources/AppDelegate.swift`; queued the latest value in `MacHost/Sources/StreamingServer.swift` until Android brightness capability negotiation; added `NativeBrightnessControllerTests`; documented the user-facing control in `README.md` and `CHANGELOG.md`
- `validation`: `swift test --package-path MacHost` passed 63 tests with 0 failures; `git diff --check` passed; `./scripts/build_mac.sh` produced a signed universal app and DMG; `/Users/tejas/Applications/SideScreen.app` was replaced and relaunched with 0 stale snapshots; the connected SM-X800 remained on ADB with reverse ports `54321` and `54322`; Android diagnostics recorded `CC: BRIGHT command` followed by `BRT: backlight applied` across slider values; the user confirmed the restored control works
- `evidence`: source, tests, signed package, installed host, live BRIGHT delivery, Android backlight application, and user-confirmed menu behavior are proven; sustained stream quality remains covered by the prior wired validation entry
- `blocker`: none
- `cleanup`: preserved the replaced installed app at `/Users/tejas/Documents/SideScreen-Backups.noindex/20260908T200700Z/installed-app/SideScreen.app`; retained all prior app/DMG backups; no source checkout, duplicate bundle, Trash item, or unrelated file was removed
- `git`: Mac-side source and documentation are ready for the already-authorized `codex/wireless-60fps-native` topic branch; no default-branch, PR, workflow, or Actions mutation
- `next`: keep the compact menu unchanged; only revisit brightness behavior if a user reports Android panel-specific range or permission differences
- `learning_checkpoint`: `promoted`: menu brightness should use the existing capability-gated control channel and queue the latest value across startup negotiation; `quarantined`: none; `skipped`: broad UI redesign, keyboard event taps, and global memory update
- `rollout_refs`: current Codex session

## 2026-09-09 — Wireless recovery action and Android reconnect UX

- `scope`: Android wireless failure recovery, cached/in-session pairing state, QR-versus-Reconnect action hierarchy, explicit Disconnect state, and the QR control-port handoff
- `baseline`: canonical `/Users/tejas/Projects/SideScreen` on `codex/wireless-60fps-native`; three Android files were already dirty before this turn and were preserved while the repair was layered onto them
- `changed`: `AndroidClient/app/src/main/java/com/sidescreen/app/WirelessTabController.kt`, `MainActivity.kt`, `WirelessRecoveryActions.kt`, `activity_main.xml`, `WirelessRecoveryActionsTest.kt`, `README.md`, `CHANGELOG.md`, and this turn record
- `validation`: `(cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon)` passed; the new recovery-action policy tests passed with the existing Android JVM suite; `git diff --check` passed; debug APK generated at `AndroidClient/app/build/outputs/apk/debug/app-debug.apk` with SHA-256 `1c1d422e7257f2bbf7afacedb6dafee8ade517b71170effc80e954e3081e945e`; Mac listener was observed on TCP ports `54321` and `54322`
- `evidence`: source implementation, unit/build validation, resource binding, and APK packaging are proven; installation, live Android UI inspection, wireless handshake, and user-confirmed reconnect behavior are not yet proven in this turn
- `blocker`: `adb devices -l` and `adb mdns services` both returned no tablet, so the new APK could not be installed or exercised; enabling wireless ADB on the tablet alone has not yet produced a paired/connected ADB transport on this Mac
- `cleanup`: no device package, ADB pairing, reverse mapping, host listener, source worktree, or unrelated file was removed; the existing running Mac listener was left unchanged
- `git`: local topic-branch changes only; no commit, push, PR, merge, workflow, or Actions mutation
- `next`: make the tablet appear in `adb devices -l` as `device` (wireless ADB pairing may require the tablet's IP plus pairing port/code), run `./scripts/install_android.sh`, then capture Android logcat and a real error → **Reconnect** → first-frame trace
- `learning_checkpoint`: `promoted`: cached pairing state must remain a valid recovery credential even when a secure preference read/write is temporarily unavailable; `quarantined`: the original live failure cause until the new APK is installed and the tablet logs are captured; `skipped`: global memory update, default-branch integration, and publication
- `rollout_refs`: current Codex session

## 2026-09-09 — Live USB install, Wi-Fi-scoped discovery, and multicast permission repair

- `scope`: install the wireless recovery build on the representative SM-X800, exercise the stale-pair failure UI, and repair Android Bonjour discovery prerequisites
- `changed`: added active-Wi-Fi network scoping and a short released multicast lock to `AndroidClient/app/src/main/java/com/sidescreen/app/SideScreenDiscovery.kt`; declared `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` in `AndroidClient/app/src/main/AndroidManifest.xml`; retained the Reconnect-first recovery UI from the preceding entry
- `validation`: `(cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon)` passed with 37 tests and 0 failures; `git diff --check` passed; APK SHA-256 is `a123629bd7c5e3383b4c98cd89cdb018de6839367032947a228b573ccb84cf8e`; `./scripts/install_android.sh --skip-build` installed it successfully and preserved the pairing; ADB reports `R52X30G5TNB` / `SM_X800`, USB reverse mappings `54321` and `54322`, and the multicast permission is granted
- `evidence`: live Android UI shows `⚠ Couldn't reach Mac` with primary `RECONNECT` and secondary `SCAN QR INSTEAD`; the Mac app was started and listens on `54321`/`54322`; a tablet TCP probe reached the Mac listener and was rejected only for missing SideScreen handshake bytes; the repaired app acquires and releases `SideScreenDiscovery` multicast lock successfully and binds NSD to Wi-Fi network `101`
- `blocker`: the cached pairing still points to `192.168.1.88`, while the current Mac is `10.0.22.156`; the tablet did not receive the advertised Bonjour service during the bounded retry even with Wi-Fi scoping and multicast permission, so an end-to-end authenticated wireless stream and automatic endpoint replacement remain unproven on this Wi-Fi; QR is no longer forced by the failure UI, but a new QR may still be needed if this network suppresses mDNS
- `cleanup`: retained recoverable APK backups at `backups/apk/20260909T191043Z`, `20260909T191721Z`, and `20260909T191945Z`; left the Mac listener running; no pairing data, app data, source checkout, or unrelated file was removed
- `git`: local changes only on `codex/wireless-60fps-native`; no commit, push, PR, default-branch, workflow, or Actions mutation
- `next`: retry on a Wi-Fi path that forwards Bonjour/mDNS between the Mac and tablet; if it still fails, capture the network's multicast policy before changing the pairing flow again
- `learning_checkpoint`: `promoted`: wireless recovery must retain the cached credential, scope discovery to the active Wi-Fi network, and release multicast reception after the bounded lookup; `quarantined`: network-specific mDNS suppression as an external condition; `skipped`: publication, global memory update, and default-branch integration
- `rollout_refs`: current Codex session

## 2026-09-09 — Wireless transport fallback and live USB proof

- `scope`: finish the live Android connection path, repair route selection for wireless video/control sockets, and verify the same installed build through the available USB transport
- `baseline`: canonical `/Users/tejas/Projects/SideScreen` on `codex/wireless-60fps-native`; the Mac host is `10.0.22.156`, the representative SM-X800 is `10.0.33.245` on WiFi network `101`, and the cached pairing token was preserved while its stale host endpoint was updated to the current Mac address
- `changed`: `AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt` and `ControlChannel.kt` now try the process-default route before the explicit WiFi `Network` route; `README.md`, `CHANGELOG.md`, and this turn record document client-isolation diagnosis and the fallback behavior
- `validation`: after the route patch, `(cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon)` passed with 37 tests and 0 failures; `./scripts/install_android.sh --skip-build` installed the debug APK and restored USB reverse mappings on `R52X30G5TNB`; the live USB session authenticated as loopback, received display config `2800x1752`, initialized the HEVC decoder, and sustained at least 6,180 decoded inputs with `dropped=0`; `git diff --check` passed before the final documentation update
- `evidence`: the wireless repair UI visibly exposes primary **Reconnect** and secondary **Scan QR instead**; both the Android shell and a temporary plain Mac TCP listener timed out across the current WiFi path, while the Mac listener was healthy and the USB path delivered frames, isolating the remaining wireless blocker below the app protocol
- `blocker`: the current WiFi path is client-isolated or otherwise blocks peer-to-peer TCP/Bonjour despite both endpoints being in `10.0.0.0/18`; no Android or Mac application change can bridge that access-point policy. Wireless remains unproven until both devices use a non-isolated SSID or client isolation is disabled
- `cleanup`: the Mac SideScreen listener and the working USB stream were left running; only task-created APK backups and the temporary device-side pairing backup remain to be reviewed; no source, pairing token, unrelated file, commit, push, PR, workflow, or Actions state was removed or published
- `git`: local topic-branch changes only; no commit, push, PR, merge, default-branch, workflow, or Actions mutation
- `next`: remove only the temporary `.codex-old` device pairing backup, rerun the final build/check and project-memory doctor, and retry wireless on a peer-reachable WiFi path; do not force QR scanning or claim wireless completion from the USB proof
- `learning_checkpoint`: `promoted`: transport verification must include a plain peer TCP probe in addition to app logs, and a same-subnet address does not prove peer reachability; `quarantined`: whether the earlier one-off TCP probe used a transient non-isolated path; `skipped`: router configuration changes, publication, and global memory update
- `rollout_refs`: current Codex session

## 2026-09-09 — Per-network socket factory fallback and wireless boundary correction

- `scope`: Android wireless video/control route selection, installed reconnect UI, fresh Mac listener restart, and current Wi-Fi acceptance evidence
- `baseline`: canonical `/Users/tejas/Projects/SideScreen` on `codex/wireless-60fps-native`; user-confirmed wired transport is good, so wireless is the only acceptance target
- `changed`: `AndroidClient/app/src/main/java/com/sidescreen/app/StreamClient.kt` and `ControlChannel.kt` now try Android's per-network `Network.socketFactory` before process-default and legacy `bindSocket` routes; `MacHost/Sources/SettingsWindow.swift` clarifies that a local Wi-Fi address does not prove peer reachability; added `docs/troubleshooting/wireless-reconnect-2026-09-09.md`; corrected the changelog route description
- `validation`: `(cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon)` passed with 37 tests and 0 failures; the installed debug APK SHA-256 is `5d5298eccd5d09592eb83e495e8a5d5b03cd7db8659bf56ee353dc0d74b47ec6`; the live Android retry logged WiFi-factory, default, and WiFi-bind route timeouts; a fresh Mac stop/start recreated the Wireless listener on `54321`/`54322`; local Mac TCP connects succeed; `git diff --check` passed
- `evidence`: installed Android UI visibly retains the saved pairing and exposes primary **Reconnect** plus secondary **Scan QR instead**; a current Android-to-Mac TCP probe timed out on both SideScreen ports; Mac-to-tablet ADB TCP and `nmap` probes also show filtered peer ports; Bonjour found no service; macOS firewall rules already permit the SideScreen app and executable; no new wireless auth or video-frame session was observed
- `blocker`: current live Wi-Fi peer traffic is filtered or otherwise unavailable despite same-subnet addresses; the exact access-point policy is not identified, and an earlier probe reached the Mac, so the environment diagnosis remains quarantined as current-path evidence rather than a universal claim. Wireless implementation and installed recovery UX are proven; wireless live/user acceptance is not
- `cleanup`: restored the tablet ADB daemon to USB mode after the wireless-debugging probe; no pairing, token, source checkout, backup, commit, push, PR, workflow, or Actions state was deleted or published
- `git`: local topic-branch changes only; no default-branch, PR, merge, workflow, or Actions mutation
- `next`: retry the installed APK on a peer-reachable Wi-Fi path and capture the first authenticated LAN connection, display config, first keyframe, and sustained wireless frame stats; do not use the working USB session as the wireless acceptance proof
- `learning_checkpoint`: `promoted`: Android wireless sockets should use `Network.socketFactory` as the primary explicit-network API with compatibility fallbacks; `quarantined`: current SSID's exact filtering policy and the earlier transient reachability discrepancy; `skipped`: firewall weakening, router mutation, global memory update, publication, and default-branch integration
- `rollout_refs`: current Codex session

## 2026-09-09 — Exact installed host/APK wireless retry

- `scope`: rebuild and install the current macOS host, restart it in Wireless mode, and retry the current paired Android client
- `changed`: installed `/Users/tejas/Applications/SideScreen.app` from the rebuilt universal bundle; no pairing reset or USB fallback was used
- `validation`: `swift test --package-path MacHost` passed 63 tests with 0 failures; `./scripts/build_mac.sh` produced and signed the universal host/DMG; `./scripts/install_mac.sh --launch` installed and code-sign verified the host; the Mac log shows Wireless mode, Bonjour advertisement, and listeners ready on `54321`/`54322`; the installed Android 0.11.2 client retried WiFi-factory, default, and WiFi-bind routes
- `evidence`: the exact installed host and APK still produce three TCP timeouts with no Mac wireless connection, while the Android UI remains on the recoverable `RECONNECT` / `SCAN QR INSTEAD` repair state
- `blocker`: current Wi-Fi peer traffic remains filtered or otherwise unavailable; no authenticated wireless handshake, first keyframe, or sustained wireless frame evidence exists on this SSID
- `cleanup`: host is left running in Wireless mode; tablet is left on the paired wireless repair screen; no token, pairing, source, or unrelated app data was removed; no commit, push, PR, workflow, or Actions mutation
- `next`: move only the two devices to a peer-reachable Wi-Fi path (or disable client isolation), then tap `RECONNECT` and capture the live wireless handshake/frame proof
- `learning_checkpoint`: `promoted`: final acceptance must use the exact installed host and APK together; `quarantined`: current SSID policy; `skipped`: USB as an acceptance substitute, firewall weakening, router mutation, publication, and global memory update
- `rollout_refs`: current Codex session

## 2026-09-09 — Publish all local Android APK snapshots from today

- `scope`: Git publication of the local Android APK recovery snapshots created on 2026-09-09
- `changed`: committed the eight dated `backups/apk/20260909T*/` snapshots, including 16 APK artifacts and their 8 manifests; no source files were changed in this publication step
- `validation`: all 16 staged APK files were SHA-256 hashed before commit; `git diff --cached --check` passed; commit `6d322b7` was pushed to `origin/codex/wireless-60fps-native` together with the prior local source checkpoint `a90daa1`
- `evidence`: the APK artifacts and provenance manifests are committed and remotely published; the live tablet remains installed with the separately verified 2026-09-08 APK rollback
- `blocker`: none for this publication request
- `cleanup`: no local APK or backup was deleted; the repository backup history remains recoverable
- `git`: topic branch pushed from `b03dd6b` to `6d322b7`; no default-branch, PR, workflow, or Actions mutation
- `next`: use the published manifest SHA-256 values when selecting a known APK for future rollback
- `learning_checkpoint`: `promoted`: APK recovery snapshots are published with their manifests when explicitly requested; `quarantined`: none; `skipped`: source rebuild, APK reinstall, and global memory update
- `rollout_refs`: current Codex session

## 2026-09-10 — Wired macOS CPU relayout fix

- `scope`: live wired macOS host CPU diagnosis, settings-window observation graph, and the isolated SideScreen source worktree
- `baseline`: canonical `/Users/tejas/Projects/SideScreen` on `codex/wireless-60fps-native` at `b4c6405`; implementation work was isolated in `/Users/tejas/Projects/SideScreen-wired-cpu-20260910` on `codex/wired-cpu-20260910`; the canonical checkout and the running installed app were preserved
- `observed`: installed `/Users/tejas/Applications/SideScreen.app` version `0.11.2` was using approximately 101% CPU while wired listeners were active on `54321`/`54322`; a five-second sample placed the dominant work on the macOS main thread in repeated SwiftUI/AppKit layout and `SettingsView.body` rendering, while the stream logs remained healthy at approximately 70–79 FPS with zero drops
- `changed`: added `MacHost/Sources/DisplayRuntimeState.swift` with a separate `DisplayPerformanceState`; moved runtime state out of `DisplaySettings`; split runtime-dependent status, performance, network, wireless, and footer content into observing child views in `MacHost/Sources/SettingsWindow.swift`; routed `AppDelegate` runtime updates through the new models; added `MacHost/Tests/SideScreenTests/DisplayRuntimeStateTests.swift`; documented the behavior in `CHANGELOG.md`; rebuilt and installed the exact user-facing `/Users/tejas/Applications/SideScreen.app`
- `validation`: `swift test --package-path MacHost` passed 65 tests with 0 failures, including two publisher-isolation regression tests; `./scripts/build_mac.sh` rebuilt arm64 and x86_64 hosts, created the universal app/DMG, and reported 0 stale snapshots; `./scripts/install_mac.sh --launch` installed and deep-signature-verified the host; all shell scripts passed `bash -n`; source references contain no remaining `settings.<runtime-state>` accesses; `git diff --check` passed; the v3 delivery ZIP SHA-256 is `c09e1dd8d8060b56fb6ddb17002bd10a4d65be993007be482297a65440dcbdeb`; live PID `14221` measured approximately 4–7% CPU across the top sample versus approximately 101% for the prior PID `13155`; the fixed sample had 0 matches for `NSWindow layoutIfNeeded` and `SettingsView.body`; USB reverse ports `54321`/`54322` remained active, host logs sustained approximately 70–78 FPS at 2.6–2.8 Mbps with zero steady-state drops, and Android logs sustained approximately 9.2–9.8 ms decode latency with zero drops/timeouts
- `evidence`: root-cause diagnosis, implementation, regression tests, release compilation, universal packaging, signing, installation, live CPU reduction, wired handshake, and steady-state stream/decode quality are proven; the exact prior installed app was preserved at `/Users/tejas/Documents/SideScreen-Backups.noindex/20260910T224923Z/pre-wired-cpu-fix/SideScreen.app`; user visual confirmation remains separate
- `blocker`: none for the current installed wired verification; the first reconnect interval recorded one host startup drop before steady-state returned to zero, and longer workload-specific CPU/visual acceptance remains optional follow-up
- `cleanup`: the new host remains installed and running with the wired session active; the prior bundle is recoverable from the dated backup; no stale app snapshot was created, no tablet/pairing data was removed, and no GitHub, PR, workflow, or Actions state was mutated
- `git`: local commit on isolated branch `codex/wired-cpu-20260910`; no push, merge, default-branch, PR, workflow, or Actions mutation
- `next`: visually confirm the running wired stream under the normal desktop workload; if CPU rises again, capture a matching `top`/`sample` window before changing the encoder or transport path
- `learning_checkpoint`: `promoted`: high-frequency runtime metrics must not be published through the root settings configuration object, and the installed A/B measurement supports that this removes the main CPU regression without changing the wired quality path; `quarantined`: user visual acceptance and the single startup drop until a longer workload-specific review; `skipped`: encoder/bitrate/resolution changes, blind copy-removal experiments, publication, and global memory update
- `rollout_refs`: current Codex session
