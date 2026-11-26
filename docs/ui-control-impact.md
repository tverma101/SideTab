# UI control and resource-impact map

This is the compact operator map for the current SideScreen UI. It records
what each visible control changes and the expected resource cost. Cost labels
are relative workload guidance, not a device benchmark:

| Cost | Meaning |
| --- | --- |
| None | UI/state or a small control packet; no pixel pipeline work. |
| Transient | Short display, decoder, socket, or shader rebuild. |
| Sustained | Work repeated while a stream is active. |
| High sustained | A deliberate quality, frame-rate, or post-processing trade-off. |

## Transport invariant

| Control / action | Does | Resource and lifecycle impact |
| --- | --- | --- |
| Mac **USB** mode + **Start** | Creates the virtual display, starts ScreenCaptureKit and the USB listener, and configures `adb reverse`. Android must use the USB tab and the loopback endpoint. | Transient setup, then sustained capture + encode + cable transfer. The host rejects non-loopback peers. |
| Mac **Wireless** mode + **Start** | Creates the virtual display, starts ScreenCaptureKit and the LAN listener, publishes `_sidescreen._tcp`, and enables token authentication. Android must use the Wireless tab. | Transient setup, then sustained capture + encode + Wi-Fi transfer. Wireless is capped at 60 FPS and the configured wireless bitrate profile. |
| Android **USB / Wireless** selector | Selects which client workflow is shown. It never probes the other transport. | None while idle. A live session cannot be switched underneath itself; disconnect first. There is no silent USB↔wireless fallback. |
| Android **Connect** (USB) | Opens the configured local USB route and waits for protocol, display configuration, decoder start, and a rendered frame. | Transient connection/decoder cost; sustained stream cost only after readiness. Failure returns to the app shell with a retryable reason. |
| Android **Reconnect** (Wireless) | Resolves the paired Mac with bounded Bonjour discovery, falls back to the paired endpoint, authenticates, and starts a fresh generation. | Transient discovery + handshake; sustained wireless stream after readiness. Old callbacks cannot claim the new generation. |
| Android **Scan / Rescan QR** | Reads a Mac pairing URL, validates it, stores the endpoint/token, and starts one authenticated wireless attempt. Invalid codes stay in the repair state. | Camera/ML Kit cost is transient; network cost is handshake-only until a frame is accepted. |
| Android **Disconnect** | Suppresses automatic reconnect, invalidates the current generation, closes video/control sockets, releases decoder/renderer/brightness ownership, and restores the shell. | Short teardown spike; capture/decode/render CPU and GPU usage drop afterward. |

The Mac mode and Android mode must describe the same active transport. A USB
listener accepts only ADB-reverse loopback; a wireless listener accepts only
authenticated non-loopback LAN clients. This prevents a stale QR address or a
network endpoint entered in the USB tab from looking like a successful but
empty connection.

## Mac settings and menu controls

| Control | Does | CPU / GPU / network impact |
| --- | --- | --- |
| **Start / Stop** | Starts or stops the virtual display, capture, encoder, listener, ADB/Bonjour setup, and brightness bridge. | Start is transient setup, then sustained capture + encode + send. Stop is transient teardown and removes the sustained load. |
| **USB / Wireless** | Persists the selected host transport. If the server is running, it stops and restarts it under the new admission/auth policy. | Transient display/server teardown and rebuild; active clients are disconnected. No sustained cost while idle. |
| **Resolution / HiDPI profile** | Uses the fixed 1400×876 logical / 2800×1752 physical tablet profile shown in the current UI. | Higher physical pixel count increases sustained capture, encode, memory bandwidth, and network work. Changing a live profile requires a server rebuild. |
| **Rotation 0/90/180/270** | Sends a display transform and updates the Android presentation orientation. | Small transient control/configuration work and possible frame reconfiguration; no material sustained CPU increase by itself. |
| **Flip Horizontally / Vertically** | Sends a horizontal or vertical display transform. | Small per-frame transform/encode impact; normally negligible CPU change, with no extra network bytes. |
| **Arrange Displays…** | Opens macOS Display Arrangement so the virtual display can be positioned relative to the Mac display. | None in SideScreen; macOS may redraw its settings UI. |
| **Tablet Brightness slider / F1/F2** | Sends the tablet backlight level over the control channel and remembers it while disconnected. | One small control packet per change; negligible CPU/network cost. F1/F2 also show a short HUD. |
| **Refresh Rate 30/60/90/120** | Selects the requested capture cadence. Wireless disables rates above its 60 FPS cap; the active session profile is logged. | Higher FPS increases sustained capture callbacks, encode work, send rate, and Android render work. USB 90/120 can be materially more expensive. |
| **Enable Touch Input** | Enables/disables Mac-side touch parsing and CGEvent injection. | Disabled: avoids touch parsing/dispatch. Enabled: small event-driven CPU/network cost; rapid touch can be sustained while used, but it does not encode more pixels. |
| **Server Port** | Changes the listener port while stopped. Wireless pairings must be rescanned after a port change. | None while idle; reconnect/handshake uses the new port. Disabled while running. |
| **Launch at Login** | Enables the macOS background login item. | None during the stream; adds only login-time process startup. |
| **Auto-start streaming on launch** | Starts the configured server mode when the Mac app opens. | Login/launch transient setup; then the same sustained streaming cost as Start. |
| **Startup mode USB / Wireless** | Selects the mode used by auto-start. | None until launch; determines whether ADB or Bonjour/auth setup runs. |
| **Gaming Boost** | Locks the effective profile to approximately 1000 Mbps, 120 Hz, and ultra-low-latency encoding. | High sustained capture/encode/network and tablet render/power load. Wireless caps still apply. |
| **Bitrate presets / slider** | Changes the target encoder bitrate (20–5000 Mbps when not locked by Gaming Boost). | Higher bitrate increases sustained encoder pressure, packet volume, and network use; CPU impact depends on hardware encoder complexity and content. |
| **Quality Preset** | Selects the encoder quality/latency preset. Gaming Boost locks it to Ultra Low. | Higher quality can increase sustained encoder work and latency; Ultra Low favors lower CPU/latency at the cost of compression efficiency. |
| **Status rows / Recheck** | Reports virtual display, client, capture, permission, ADB, USB, Wi-Fi, and listening state; Recheck refreshes diagnostics. | None or a short status query. The Android USB checklist remains advisory and does not open a competing probe socket. |
| **Request Access / Open Settings / Copy Identity** | Repairs or explains macOS Screen Recording identity/TCC state. | None to the stream; opening Settings is an OS UI action. |
| Wireless **QR**, **Refresh**, **Forget**, **Reset Token** | Displays the current authenticated pairing URL; refreshes device status; removes one pairing; or revokes all wireless tokens. | QR/status UI is negligible. Reset/forget causes reconnect/auth failure until the device pairs again; no pixel cost while idle. |
| **Restart** | Launches a new app instance and terminates the current one. | Transient full process/server teardown and startup; active clients disconnect. |
| **Quit** / menu **Quit Side Screen** | Terminates the host app and its stream. | Transient teardown; sustained host load stops. |
| Header **Reset Settings** | Restores saved UI/stream settings to defaults. | Usually preference/UI work; settings that are observed by a live session can cause the corresponding encoder or transform update. |

## Android streaming controls

| Control | Does | CPU / GPU / network impact |
| --- | --- | --- |
| **Advanced Settings** | Shows or hides the client controls below. | None. |
| **Show stats** | Shows FPS, bitrate, latency, and renderer diagnostics overlay. | Small UI/compositor and text-update overhead; no additional video network traffic. |
| **VSR on/off** | Rebuilds the video path between direct presentation and the GPU post-process bridge. | Transient decoder/renderer rebuild; enabled mode adds sustained GPU work and a small render-thread CPU cost. |
| **VSR mode: Bridge / SGSR / CAS** | Selects the GPU post-process shader family and restarts that video path. | Transient shader/renderer rebuild; sustained GPU cost varies: Bridge is lowest, SGSR/CAS add shader sampling. |
| **VSR Sharpness / Edge Threshold** | Updates shader parameters live without reconnecting. | No socket cost; sustained per-pixel GPU math changes slightly, usually far below changing resolution/FPS. |
| **Android color profile** | Enables the calibrated color transform on the supported GPU path; USB direct path may rebuild to apply it. | Small sustained per-pixel GPU cost; a direct-path toggle can cause a transient local renderer rebuild, not a transport reconnect. |
| **Hide settings button** | Hides the floating settings control during streaming; back gesture temporarily reveals it. | None apart from tiny UI state/timer work. |
| **Overlay opacity / position / reset position** | Changes diagnostics/settings overlay alpha or location. | None to the stream; small compositor cost while overlays are visible. |
| **Forget paired Mac** | Deletes the saved wireless endpoint/token and returns to first-time pairing. | None while idle; cancels future automatic reconnect. |
| **Open Settings** (permission repair) | Opens Android camera permission settings when QR scanning is blocked. | None to video; camera is used only when scanning. |

## Readiness and failure notes

- A TCP connection is not displayed as success. The Android state machine waits
  for protocol negotiation, display dimensions, decoder startup, and a rendered
  frame. A 10-second readiness watchdog closes a half-connected generation and
  shows the reason.
- Surface cleanup hides the presentation views; it does not call
  `TextureView.setBackgroundColor()` or claim a `SurfaceView` Canvas buffer.
  That keeps the next MediaCodec/EGL producer from inheriting the old buffer
  queue and prevents the former Android process-kickout failure.
- Renderer viewport dimensions are re-queried after fullscreen/inset changes.
  The initial inset size can therefore grow to the full tablet panel without a
  persistent black strip.
- Control-channel loss degrades brightness/ping/touch capabilities but does
  not declare a healthy video stream dead. Video transport loss, decoder
  failure, invalid handshake, stale wireless endpoint, and host lifecycle
  suspension each invalidate the current generation before teardown.
- The source-level behavior and tested USB receipt are recorded in
  [the PR #43 troubleshooting record](troubleshooting/pr43-connectivity.md).
  A fresh physical wireless cycle and long lock/sleep hardware cycle remain
  separate acceptance checks.
