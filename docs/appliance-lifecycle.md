# SideScreen appliance lifecycle contract

Tracks #39 with implementation children #40, #41, and #42. This contract also extends #23 (Android session authority) and #34 (Protocol V2 session identity).

## Product behavior

```text
Streaming
  ↓
Mac lock / screensaver / display sleep / system sleep
  ↓
Host lifecycle enters suspended state
  ↓
no more desktop pixels from the old generation
  ↓
Android stops presenting old frames
releases keep-screen-on / decoder / renderer / brightness ownership
  ↓
Android may naturally turn its display off
  ↓
user wakes/unlocks Android
  ↓
bounded reconnect to the paired Mac
  ↓
fresh authenticated SideScreen session/generation + fresh keyframe
  ↓
first current-generation frame rendered
  ↓
Streaming
```

## Invariants

1. A locked Mac is not a video source. SideScreen must not treat the macOS lock screen as ordinary remote-desktop content.
2. Suspend reasons compose. If the Mac locks and then sleeps, system wake alone does not resume pixels while the login session is still inactive.
3. Persistent pairing identity survives suspend; live video/control session identity does not.
4. Android keep-awake ownership belongs only to a current-generation streaming session.
5. Android must not require root, Device Admin, hidden sleep APIs, or global `SCREEN_OFF_TIMEOUT` mutation merely to let the tablet sleep.
6. Explicit user Disconnect suppresses wake auto-reconnect. Host suspend, transient network loss, or app recreation may be retryable.
7. A wake/reconnect attempt cannot replace an already healthy session and stale attempts cannot affect a newer generation.
8. The first visible frame after wake must come from the new authoritative generation. Never flash a cached pre-suspend frame.

## Mac lifecycle sources

`AppDelegate` maps supported macOS workspace/power signals into
`HostLifecycleController` reasons. The pure controller intentionally does not
depend on AppKit or IOKit so overlapping/racy lifecycle behavior is deterministic
and unit-testable.

Expected mappings include:

- user session inactive/active → `sessionInactive`
- screensaver start/stop → `screenSaver`
- display sleep/wake → `displaySleep`
- system will sleep/did wake → `systemSleep`

Workspace notifications are delivered on the main queue. Distributed
notifications cover screensaver start/stop and the lock/unlock compatibility
names. No global HID/event tap is used.

While a reason is active, `StreamingServer` closes only the active client and
keeps both TCP listeners available. `ScreenCapture` gates frame callbacks before
stopping `SCStream`, drains the encode queue, invalidates VideoToolbox, releases
the display-sleep assertion, and clears the cached pixel buffer. If WindowServer
drops the virtual display, the saved session-local configuration is recreated on
wake before capture resumes.

## Android lifecycle

`SessionController` remains the single session truth. `SessionLifecyclePolicy`
is only a pure classifier for reconnect and keep-awake decisions; the runtime
uses it from `MainActivity` without creating a second connection state machine.

On host suspend or terminal video loss Android should eventually reach a low-cost state with:

- no old frames presented;
- decoder/render loop quiesced;
- `FLAG_KEEP_SCREEN_ON` cleared;
- SideScreen brightness ownership released;
- high-frequency ping/stats/checklist work stopped;
- only bounded discovery/reconnect state retained.

Wake/foreground auto-reconnects only when a paired host exists and the previous
termination reason is retryable. The QR endpoint is tried first; after a network
failure Android performs a bounded NSD lookup for the Mac's `_sidescreen._tcp.`
service and persists a successfully resolved address. Retries use 500 ms to 30 s
capped exponential backoff with jitter. User Disconnect persists a suppression
flag until the user starts a connection or scans a new QR code; revoked
authentication and fatal protocol errors require explicit user action.

## Lifecycle protocol extension

The Android client advertises lifecycle support with payload-free client message
type `16`. A capable Mac sends `HostSuspending(reason)` as server message type
`17` with one reason byte (`1=sessionInactive`, `2=screenSaver`,
`3=displaySleep`, `4=systemSleep`) before closing/quiescing the active session.
The message is advisory for fast UX, not the only safety mechanism: local Mac
lifecycle state independently stops frame admission. Older peers safely ignore
the one-byte capability and never receive the unsolicited server message.

Resume creates a new video session generation and fresh video/control sockets;
the persistent pairing token remains the credential used by the next wireless
handshake. Pre-suspend frame/control/brightness messages are stale by definition.

## Implemented boundary

PR #43 now includes:

- pure Mac lifecycle state/reason semantics and overlap tests;
- AppDelegate workspace/distributed lifecycle observation;
- capture, encoder, virtual-display, and server quiesce/resume wiring;
- capability-gated `HostSuspending(reason)` compatibility;
- Android screen/activity lifecycle teardown and generation fencing;
- Android decoder/renderer/brightness/keep-awake release on suspension;
- paired-host auto-reconnect, NSD discovery fallback, suppression, and backoff;
- deterministic policy/controller tests and this cross-platform contract.

The implementation is source-complete, but target-hardware runtime receipts are
still a separate evidence state. They are not implied by local compilation or
unit tests.

## Runtime acceptance before merge

At minimum collect target-device receipts before changing the PR out of Draft:

- 50 Mac lock/unlock cycles;
- 20 Mac system sleep/wake cycles;
- 100 Android screen-off/on wake/reconnect cycles;
- both devices sleeping and waking in either order;
- Wi-Fi missing during suspend then returning;
- Mac process restart while Android sleeps;
- stale reconnect completion after a newer generation succeeds;
- explicit user Disconnect followed by Android sleep/wake (must remain disconnected).

Receipt timestamps should include lifecycle signal, final old-generation frame,
host quiesced, Android suspended, wake/foreground, reconnect attempt, transport
ready, authenticated session ready, first keyframe, first decoder output, and
first Surface-rendered fresh frame. Local tests prove policy/state behavior only;
they do not prove these hardware receipts.
