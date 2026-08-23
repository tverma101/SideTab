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

The external high-speed-camera measurement of physical panel latency remains a
separate hardware test; software timestamps do not replace that measurement.
