# Android session lifecycle

SideScreen has one authoritative Android session state. Transport callbacks,
the USB checklist, decoder readiness, control-channel health, and presentation
ownership are inputs to that state; they are not independent connection flags.

## States and ownership

| State | What is allowed | What is not owned |
| --- | --- | --- |
| `Idle` / `Preflight` | Normal app UI and local advisory checks | Decoder, fullscreen bars, touch forwarding, screen-awake flag, tablet brightness |
| `Connecting` / `Negotiating` | Current-generation transport and protocol work | Stream presentation and brightness |
| `WaitingForFirstFrame` | Decoder output may be accepted while waiting for actual render evidence | Fullscreen, touch forwarding, and brightness |
| `Streaming` | Fullscreen, screen-awake flag, decoder, touch forwarding, and transactional brightness | Nothing outside the current generation |
| `Reconnecting` | Bounded paired-host discovery/retry | Decoder, renderer, fullscreen bars, touch forwarding, brightness, keep-awake |
| `SuspendedWaitingForHost` | Low-cost wait for host wake or Android foreground | Old transport, old frames, decoder, renderer, brightness, keep-awake |
| `Disconnecting` / `Disconnected` / `Failed` | Idempotent teardown and retry UI | All stream resources |

`Streaming` requires all of the following for the same connection generation:

1. transport connected;
2. display configuration and protocol negotiation accepted;
3. decoder started;
4. a decoded frame reached the render path (`MediaCodec.OnFrameRenderedListener`
   for direct output, or the renderer completion for buffer output).

The optional control channel is a capability. Its loss changes the session to
`control degraded` while video remains `Streaming` if the render path is
healthy.

Host lock/sleep uses the same generation fence. A capable Mac sends a
`HostSuspending` advisory before closing the video/control sockets; Android
immediately invalidates the generation, clears the presentation surface,
releases the decoder/renderer and transactional brightness ownership, and
allows normal Android display sleep. Activity `onStop` and screen-off broadcasts
use the same teardown path, so backgrounding does not leave a live decoder or a
60-second delayed connection alive.

When the paired host is available again, Android first retries the saved QR
endpoint. After a network failure it performs a bounded `_sidescreen._tcp.` NSD
lookup using the paired Mac name, then retries the resolved address. Backoff is
capped at 30 seconds with small jitter. Explicit Disconnect sets a persistent
suppression flag and is the only normal path that requires a new user action to
resume reconnecting.

## Brightness ownership

The Android client snapshots system brightness mode/value and the window
override only when `Streaming` begins. It writes a requested value only for
the current generation. On teardown it restores a snapshot only when the
current value still equals SideScreen's last write; a user change wins. A
window-fallback restore is also skipped if a newer session has already taken
ownership.

## USB checklist boundary

`UsbManager.deviceList` is not a valid readiness signal for SideScreen's
ADB-reverse topology: Android is the USB device and the Mac is the USB host.
The checklist therefore reports the USB route and Mac listener as “verified
when you tap Connect.” It still reports local Developer Mode and ADB settings,
but it never opens a background probe that could contend with the real client.

## Transport admission and presentation geometry

The selected transport is an admission boundary, not only a UI preference:

- USB uses the local ADB-reverse endpoint (`127.0.0.1`/`::1`). The Mac USB
  listener accepts loopback only and does not advertise a Bonjour service.
- Wireless uses the paired endpoint or `_sidescreen._tcp.` discovery. The Mac
  wireless listener accepts authenticated non-loopback LAN peers only.
- A cached wireless address cannot silently become a USB connection, and a
  USB reverse endpoint cannot silently become a wireless connection. A mode
  mismatch is rejected before protocol state is changed.

Android enters fullscreen only after the current generation has rendered a
  frame. The decoder and optional EGL bridge may be initialized while system
  bar insets still exist; the renderer therefore re-queries the live window
  surface and updates its viewport when the presentation surface expands.
  This prevents a stale inset-sized viewport from leaving a black strip on the
  tablet after the bars are hidden.

## Runtime evidence

For an installed run, collect:

- `MA` state/presentation messages showing idle → negotiating → waiting →
  streaming → disconnected;
- `BRT` acquisition, application, and conditional restoration messages;
- `VD` selected decoder evidence, configure path, codec metrics, and
  `release->surface` timing;
- Mac `Pipeline` messages separating WindowServer → callback, encode, queue,
  and send-completion latency;
- system-bar/brightness snapshots before idle, during streaming, and after
  disconnect.
- `HostSuspending` reason, Android `SuspendedWaitingForHost`, reconnect attempt,
  NSD candidate, and fresh-generation first-render timestamps.

The external high-speed-camera measurement of physical panel latency remains a
separate hardware test; software timestamps do not replace that measurement.
