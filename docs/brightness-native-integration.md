# SideScreen brightness integration contract

Tracks #35. This document separates two goals that must not be conflated:

1. **real tablet panel luminance control** — already possible through Android;
2. **true macOS-native brightness routing for the SideScreen virtual display** — not yet proven possible.

## Current truth

The Mac currently intercepts brightness/F1/F2 intent and sends a SideScreen BRIGHT command. Android then changes either global system brightness or the streaming Activity's window brightness. This is a remote panel-control bridge, not proof that macOS considers the CGVirtualDisplay a native brightness-capable display.

## Feasibility probe first

On the exact SideScreen CGVirtualDisplay ID, preserve a local receipt covering:

- DisplayServices brightness query result/status;
- DisplayServices set result/status;
- System Settings / Control Center brightness exposure;
- relevant IOKit display service/registry properties;
- comparison against a known Apple brightness-capable display;
- whether any CGVirtualDisplay descriptor/settings property can provide brightness capability;
- whether native F1/F2 can target SideScreen without an app-owned global key hook.

Do not ship a private-API dependency merely because a symbol can be called. Record Tahoe/macOS 26 behavior and failure codes.

## Decision A: native provider works

If macOS can treat SideScreen as a brightness-capable display:

- use that native source of brightness intent/state;
- translate the resulting normalized display brightness into the active SideScreen Protocol V2 session;
- remove the global F1/F2 interception path;
- verify Control Center/System Settings/F1/F2 all agree on state;
- preserve real Android panel luminance changes.

## Decision B: native provider is unavailable

Then implement the smallest Apple-like bridge:

- exactly one brightness-key observation mechanism;
- acquire only while an authenticated active SideScreen streaming session owns brightness;
- release immediately on disconnect/stop/failure;
- no brightness observer when SideScreen is disconnected;
- no duplicate HID + global NSEvent delivery;
- no mouse/scroll observation in the brightness subsystem;
- pass F1/F2 through normally when no SideScreen session owns them;
- one canonical normalized brightness state shared by Settings slider, F1/F2 and reconnect replay;
- display an Apple-like OSD if practical without claiming native display-service integration.

## Android default ownership

Prefer `WindowManager.LayoutParams.screenBrightness` while the streaming Activity owns presentation.

Default SideScreen operation must not require `WRITE_SETTINGS`, must not force `SCREEN_BRIGHTNESS_MODE_MANUAL`, and must not mutate user-wide tablet brightness merely to dim the active SideScreen surface.

Keep a global system-brightness path only as an explicitly measured fallback if target hardware proves the window path cannot change physical panel luminance acceptably.

## Protocol V2 integration

Brightness commands must be bound to #34 session identity. Conceptual messages:

- BrightnessCapability
- BrightnessState
- SetBrightness(sessionId, sequence, normalizedValue)
- optional BrightnessAck

Stale session/generation messages must be ignored before any Android brightness mutation.

## Acceptance tests

Mac:
- F1/F2 active session => one ordered brightness change per step;
- F1/F2 disconnected => normal macOS behavior;
- zero leaked taps/monitors after repeated connect/disconnect;
- Secure Input/fallback behavior tested;
- WindowServer CPU compared with brightness hooks on/off;
- DisplayServices native-integration probe receipt preserved.

Android:
- window-scoped brightness changes visible SM-X800 luminance;
- auto-brightness mode unchanged on default path;
- Activity recreation/process death/host loss restore correctly;
- stale generation cannot change luminance;
- user intervention is preserved during teardown;
- rapid brightness stepping remains smooth.

Cross-device:
- trace F1/F2 intent -> Mac control send -> Android receive -> apply;
- measure p50/p95/p99 control latency;
- reconnect replay is session-bound;
- bogus/stale control connection cannot change brightness.

## Evidence baseline

Open-source display-control projects such as MonitorControl distinguish native Apple/built-in brightness control from virtual/AirPlay/Sidecar/DisplayLink screens, which use software/shade alternatives. Treat that as a reason to test CGVirtualDisplay native capability explicitly, not as absolute proof that SideScreen cannot expose one on this macOS build.
