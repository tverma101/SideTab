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
fresh Protocol V2 session + fresh keyframe
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

The live implementation under #40 must map supported macOS workspace/power signals into `HostLifecycleController` reasons. The pure controller intentionally does not depend on AppKit or IOKit so overlapping/racy lifecycle behavior is deterministic and unit-testable.

Expected mappings include:

- user session inactive/active → `sessionInactive`
- screensaver start/stop → `screenSaver`
- display sleep/wake → `displaySleep`
- system will sleep/did wake → `systemSleep`

Observation APIs and any compatibility fallback must be documented with runtime receipts. Do not add another global HID/event tap.

## Android lifecycle

`SessionController` remains the single session truth. `SessionLifecyclePolicy` is only a pure classifier for reconnect and keep-awake decisions; implementation under #41/#42 must integrate it into the controller rather than creating Activity-local connection state.

On host suspend or terminal video loss Android should eventually reach a low-cost state with:

- no old frames presented;
- decoder/render loop quiesced;
- `FLAG_KEEP_SCREEN_ON` cleared;
- SideScreen brightness ownership released;
- high-frequency ping/stats/checklist work stopped;
- only bounded discovery/reconnect state retained.

Wake/foreground should auto-reconnect only when a paired host exists and the previous termination reason is retryable. User Disconnect, revoked authentication, and fatal protocol errors require explicit user action.

## Protocol V2 requirement

When possible the Mac should send an authenticated `HostSuspending(reason)` (exact wire name/layout TBD by #34) before closing/quiescing the active session. The message is advisory for fast UX, not the only safety mechanism: local Mac lifecycle state must independently stop frame admission.

Resume creates a new video session ID/generation and fresh control credential. Pre-suspend frame/control/brightness messages are stale by definition.

## Draft PR boundary

This first PR intentionally establishes only:

- pure Mac lifecycle state/reason semantics;
- Android reconnect/keep-awake policy semantics;
- deterministic tests;
- the cross-platform contract in this document.

It does **not** yet wire:

- macOS notifications into `AppDelegate`;
- ScreenCaptureKit/VideoToolbox quiesce and restart;
- Protocol V2 suspend messages;
- Android decoder/renderer/brightness teardown;
- Android screen-off/foreground observers;
- discovery/backoff or actual automatic reconnect;
- target-hardware runtime receipts.

Those omissions are why the PR must remain Draft.

## Runtime acceptance before merge

At minimum collect target-device receipts for:

- 50 Mac lock/unlock cycles;
- 20 Mac system sleep/wake cycles;
- 100 Android screen-off/on wake/reconnect cycles;
- both devices sleeping and waking in either order;
- Wi-Fi missing during suspend then returning;
- Mac process restart while Android sleeps;
- stale reconnect completion after a newer generation succeeds;
- explicit user Disconnect followed by Android sleep/wake (must remain disconnected).

Receipt timestamps should include lifecycle signal, final old-generation frame, host quiesced, Android suspended, wake/foreground, reconnect attempt, transport ready, Protocol V2 session ready, first keyframe, first decoder output, and first Surface-rendered fresh frame.
