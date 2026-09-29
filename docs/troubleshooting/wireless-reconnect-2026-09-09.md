# Wireless reconnect investigation — 2026-09-09

## Scope

This record covers the Android wireless reconnect failure and the recovery UI
reported as QR-only. The acceptance boundary is a real authenticated wireless
session with video frames; the known-good USB session is transport sanity proof
only.

## Symptoms

- Android could show “Couldn't reach Mac” without a usable reconnect action.
- A saved pairing was present, but the UI made QR scanning look like the only
  recovery path.
- The Mac listener was healthy locally, while wireless attempts from the
  representative SM-X800 timed out.

## Implemented changes

- A cached pairing now remains available in memory and on disk after a
  transient failure.
- `Reconnect` is the primary action for a known pairing. `Scan QR instead` is
  secondary and becomes primary only when a token was rejected or no pairing
  exists.
- Bonjour recovery is scoped to the active Android Wi-Fi `Network` and holds a
  released multicast lock for the bounded lookup.
- Video and control sockets try Android's per-network `Network.socketFactory`
  route, then the process-default route, then the legacy `bindSocket` route.
- Pairing QR and Bonjour recovery now preserve multiple usable LAN addresses,
  preferring IPv6 on the physical interface and falling back to IPv4. Android
  persists those alternates and uses the address that completes the video
  handshake for the control channel too.
- The unproven `LocalOnlyHotspot` / Private Link workaround was removed. The
  tablet stays on its normal Wi-Fi and keeps its Internet route.

## Current evidence

- `(cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug --no-daemon)`
  passes with 37 tests and 0 failures.
- The updated APK is installed on `R52X30G5TNB` / `SM_X800`; the live UI shows
  `RECONNECT` and `SCAN QR INSTEAD` while retaining the saved host.
- The Mac app is in Wireless mode and listens locally on `54321` and `54322`;
  local TCP connects to `10.0.22.156` succeed.
- A fresh wireless reconnect tried all three Android socket routes. Each timed
  out from `10.0.33.245` to `10.0.22.156:54321`, and the Mac recorded no new
  wireless connection.
- The universal macOS host was rebuilt, installed, started in Wireless mode,
  and retried with the same result: the listener logged ready on both ports,
  but no authenticated wireless candidate arrived.
- A reverse-direction probe to the tablet's temporary ADB TCP port also did
  not connect. A Mac `nmap` scan reports the tablet host as present but ports
  `5555`, `54321`, and `54322` as filtered. Bonjour discovery likewise finds
  no SideScreen service.
- The Mac application and executable are already permitted by the macOS
  firewall. A fresh Mac server stop/start did not change the wireless result.

## Root-cause status

The current live Wi-Fi path is filtering peer-to-peer TCP and Bonjour between
the two devices even though both addresses are in `10.0.0.0/18`. The exact
access-point policy is not identified, and an earlier one-off probe did reach
the Mac listener, so intermittent network behavior remains quarantined rather
than promoted as a universal rule. The app-side recovery and route fixes are
implemented, but an authenticated wireless stream is not proven on this
current path.

## Recovery / next validation

Retry the installed build on a Wi-Fi path that permits client-to-client TCP and
Bonjour (for example, a non-isolated private SSID), or disable client
isolation on the current access point. Tap `Reconnect` first; do not discard
the pairing or force a new QR scan unless the Mac actually rejects the token.

## Evidence boundary

- `implemented`: Android recovery UI, Wi-Fi-scoped discovery, and socket-route
  fallback.
- `tested`: Android JVM suite and debug APK build.
- `installed`: updated debug APK on the representative tablet.
- `live`: Mac listener and USB stream; wireless attempts reach the Android
  timeout path but do not reach an authenticated Mac session.
- `user-confirmed`: wired works; wireless remains the outstanding acceptance
  target.

## 2026-09-11 — Home-network wireless recovery verified

- `scope`: repair the QR-only recovery experience and make the saved pairing reconnect reliably on the normal home Wi-Fi network
- `baseline`: canonical `/Users/tejas/Projects/SideScreen` on `codex/wireless-60fps-native`; the tablet had a saved pairing whose cached IPv4 endpoint was stale, and the user-confirmed wired path was not the wireless acceptance target
- `changed`: Reconnect is the primary action for a cached pairing; QR is explicitly secondary (`Pair again (scan QR)`); Bonjour recovery now collects all usable IPv4/IPv6 addresses; the Mac advertises those addresses in the pairing URL; Android persists and tries the alternates, then binds the control channel to the host that completes video authentication; the removed Private Link/LocalOnlyHotspot path is no longer part of recovery
- `validation`: Android `testDebugUnitTest` and `assembleDebug` passed; `swift test --package-path MacHost` passed 65 tests with 0 failures; `./scripts/build_mac.sh` and `./scripts/install_mac.sh --launch` succeeded; APK SHA-256 is `d65fb54c40bbc2d9382bea5faeef1df66c6a4016de5a9b9e1b8978ae758f10e5`
- `evidence`: the rebuilt APK was installed over the preserved app data on `SM_X800`; the visible screen showed **RECONNECT** instead of forcing QR; the stale cached endpoint timed out, then Bonjour recovered four home-network endpoints and the client authenticated on IPv6; after more than 1,080 received frames, decoder stats reported `input=1080`, `output=1079`, `dropped=0`, with continuous control `PONG` traffic
- `evidence_boundary`: `implemented`, `tested`, `installed`, and `live` are proven for this home-network session; `user-confirmed` remains pending a direct visual confirmation from the user
- `blocker`: none observed on the current home network; a different SSID that blocks peer TCP or Bonjour can still prevent discovery/transport because that is an access-point policy, not a QR-repair state
- `cleanup`: no pairing reset, source deletion, APK deletion, or router/firewall mutation; the Mac host and tablet were left in the working wireless session
- `git`: local changes remain uncommitted on the topic branch and were not pushed in this repair turn; no default-branch, PR, workflow, or Actions mutation
- `next`: use **Reconnect** for future transient failures; scan QR only when pairing is absent or the Mac rejects the token; commit/push the source repair only when explicitly requested
- `learning_checkpoint`: `promoted`: reconnect recovery must be pairing-preserving and dual-stack/multi-address; `quarantined`: behavior on peer-isolated SSIDs; `skipped`: private hotspot, relay, router mutation, and publication
- `rollout_refs`: current Codex session
