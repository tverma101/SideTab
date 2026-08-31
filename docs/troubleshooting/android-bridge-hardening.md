# Android ↔ macOS bridge hardening

Status: partial implementation on 2026-08-30. The code and deterministic
tests are saved on the topic branch; installed-app, real USB, real wireless,
and visual tablet checks are still separate evidence gates.

## Issue record

| Symptom | Cause | Current handling | Evidence |
| --- | --- | --- | --- |
| Connect appeared to work, then the tablet was kicked back to idle | StreamClient swallowed setup/read failures and emitted an unqualified disconnect | Setup errors are rethrown; pre-display reads have a bounded 5-second admission timeout; read failures publish a transport reason; cleanup and status callbacks are idempotent | Android unit build/test |
| USB and Wireless could be selected independently of the Mac route | The old listener admitted loopback and LAN connections without a shared mode contract | Mac admits USB only from loopback/ADB-reverse and Wireless only from LAN plus token auth; Android sends a marked mode hello and understands an admission result | Android/Mac protocol tests; live route test pending |
| A second client or checklist probe could evict an active stream | The listener promoted any new socket before proving that it was a real, correctly routed client | USB contenders must pass a complete mode/legacy protocol proof; Wireless contenders must pass token auth; silent, malformed, wrong-route, and wrong-mode contenders are rejected without cancelling the live client | Pure Mac contender-probe tests; live reconnect test pending |
| A Wireless control socket could replace touch/brightness handling without auth | The dedicated control listener had no route or pairing gate | USB control is loopback-only; Wireless control is LAN-only and uses the same pairing token; failed candidates remain pending and cannot replace a healthy control socket | Mac source review; live control failover pending |
| Checklist showed USB cable connected and Mac server without observing either | Android cannot truthfully infer the Mac-side ADB reverse/listener state without opening a competing stream | Local settings are PASS/FAIL/UNKNOWN; route and Mac state stay UNKNOWN/PENDING until the real Connect path reports socket, admission, display, or frame evidence | Pure checklist tests |
| Wireless showed connected before a display was actually usable | Pairing UI was updated during negotiation and loaded KeyStore state on the main thread | Wireless success is projected only from Streaming; pairing reads/saves/clears are off the main thread; repair has explicit Reconnect and QR recovery paths | Android unit build; device lifecycle pending |
| The app could remain on a blank first-frame wait with no recovery control | The settings panel was hidden as soon as the socket connected, before a frame was rendered | The panel remains visible while waiting; USB and Wireless expose Cancel, and the session is not called Streaming until the render path confirms a frame | Android source/build; visual device check pending |
| Android display did not fill the tablet panel | A near-native encoded size was used as the SurfaceView size, creating a centered border when Mac and tablet geometry differed | SurfaceView remains parent-constrained; encoded dimensions remain decoder metadata only | Surface layout unit test; visual device check pending |
| Malformed Mac display metadata could destabilize decoder/layout setup | Width, height, rotation, and transform flags were consumed without bounds checks | Android validates dimensions, rotation, and mirror bits before applying layout or initializing the decoder | Display-config unit tests |
| Reconnect/decoder callbacks raced a newer attempt | Old StreamClient callbacks could outlive the current Activity generation | SessionController generation fence plus serialized state publication and one-shot StreamClient teardown | Existing session stress tests and Android unit test |
| Swift test failed only under parallel execution | Several tests shared one UserDefaults suite and cleared each other’s experiment values | Capture frame-rate tests use a unique suite per test | Swift parallel test |

## Mode contract

The selected mode is a transport admission boundary, not only a UI preference.

- USB: Android connects through the ADB-reverse loopback route; the Mac
  listener rejects non-loopback clients.
- Wireless: Android connects to the Mac LAN address after QR token auth; the
  Mac listener rejects loopback clients.
- The current client sends a two-byte marked mode hello. The current Mac
  answers with an accepted/rejected result and expected mode, then closes a
  rejected stream.
- A wrong-route client receives an explicit wrongTransport result before the
  Mac closes the socket, so Android can distinguish “use USB” from a dead Mac.
- The dedicated control socket follows the same route boundary. Wireless
  control additionally sends the existing pairing request and is installed only
  after the Mac returns an auth OK response; USB control clears that auth
  requirement because ADB-reverse is the route boundary.
- The old V1 stream remains readable for older clients. Strict mode admission
  requires the updated Mac host; update both sides before using this guarantee
  against mixed-version installations.

There is deliberately no idle TCP probe. A probe is indistinguishable from a
real screen-sharing client to the Mac listener and can make a flaky setup look
healthy. The first explicit Connect is the bridge check.

## Control map and resource impact

The impact column is qualitative until a device profile is captured. Stream
cost means Mac capture/encode, Android decode, network transfer, and display
work after a session is genuinely streaming.

| Control | Does | CPU/GPU/battery impact |
| --- | --- | --- |
| USB / Wireless toggle | Stores the selected mode, changes visible instructions, and is disabled during an active generation; it does not connect | Negligible while idle |
| Connect | Starts one video attempt, sends the mode/capability hello, optionally starts the control channel, and waits for display/frame evidence | Setup cost; stream cost only after the Mac sends video |
| Scan QR Code | Runs the camera/ML Kit scanner, validates the URL, securely persists the pairing, and starts Wireless Connect | Camera/ML Kit cost only while scanner is open; secure save is off-main |
| Reconnect | Reuses the cached encrypted pairing and starts one explicit Wireless attempt; it never loops in the background | Same as Connect if successful; no idle reconnect cost |
| Disconnect | Invalidates the generation, closes video/control sockets, releases decoder/render resources, restores presentation/brightness ownership | Short teardown spike; removes stream cost |
| Forget this Mac | Cancels pending persistence, invalidates the stored pairing, clears encrypted preferences/key material, and returns to first-time UI | Short crypto/storage work off-main; no stream cost |
| Settings gear | Opens local overlay, presentation, VSR, color-profile, and disconnect controls | Negligible unless a video-path setting is changed |
| VSR: Bridge-only | Rebuilds the local video path with a GPU color/upscale pass and the USB bridge cap | GPU cost and usually higher power; USB bridge is capped at 60 FPS |
| VSR: SGSR/CAS | Rebuilds the local video path with sharpening; slider changes update shader parameters | GPU cost; sharper modes can increase power and may look less native |
| VSR: CfL | Uses the buffer/Image path for luma-guided chroma reconstruction | Highest Android CPU/memory pressure of the render modes; fallback is automatic when image planes are unavailable |
| Color profile switch | Rebuilds the direct USB GPU path when applicable, otherwise updates an existing renderer | GPU cost only on the renderer path; no network/encode cost |
| Brightness | Sends one low-rate control command and changes the tablet backlight | Negligible CPU/network cost; changes physical panel power, not stream bitrate |
| Touch/drag | Serializes touch packets and sends them over control/video transport | Small per-event CPU/network cost proportional to input rate; no extra capture cost by itself |
| Mac Start / Stop | Creates or tears down the virtual display, capture, encoder, listeners, and route policy | Start has a one-time display/capture/encoder spike; streaming cost continues only while a client is admitted; Stop removes it |
| Mac USB / Wireless mode | Restarts the running Mac server with the selected route and auth contract | Short teardown/start spike; Wireless pairing adds token/QR work but no idle stream cost |
| Mac resolution / FPS / bitrate | Rebuilds or reconfigures the virtual display and encoder profile | Higher resolution, FPS, or bitrate increases WindowServer, capture, encode, network, and Android decode/power work |
| Mac touch toggle | Enables or drops incoming touch messages at the host boundary | Negligible while idle; disabling can reduce input dispatch work but does not change video cost |
| Mac Reset Token | Replaces the persisted Wireless pairing token | Short local crypto/storage work; existing Wireless clients must re-pair and it does not start capture |

The control channel is automatic rather than a user-facing button: it carries
low-rate ping/pong, keyframe requests, brightness, and touch when available.
Wireless adds one bounded auth exchange. If that optional socket is unavailable,
video remains authoritative and Android falls back to the in-band path; no
background retry loop is started.

On the Mac, Start creates the virtual display/capture pipeline; actual frame
encode/send work is admitted only while a client is live. Higher resolution,
HiDPI, FPS, and bitrate increase WindowServer, capture, encoder, bandwidth, or
tablet decode work. Reset Token is local crypto/storage work and does not
restart capture.

## Test and acceptance matrix

Implemented and locally tested:

- Android unit tests: mode-frame encoding/decoding, malformed-frame rejection,
  checklist evidence including unverified legacy streaming, display-config
  bounds, SurfaceView layout policy, session ownership, storage envelope,
  frame/keyframe, clock, brightness, and transport-profile tests.
- Mac Swift tests: mode/route admission, contender proof classification,
  auth, frame pipeline/backpressure, display/codec policies, and
  parallel-safe frame-rate defaults.
- Repository tests: cross-language mode constants, version/identity, workflow
  permissions, manifest boundaries, and frame-trace analysis.

Not yet proven by this branch:

- Installed APK and Mac bundle are not replaced by this topic branch.
- Real SM-X800 USB connect with Mac in USB mode, including unplug/replug.
- Real SM-X800 Wireless connect with Mac in Wireless mode, including WiFi
  loss/reconnect and token rejection.
- Deliberate wrong-mode/wrong-route attempts show the expected user message.
- A failed Wireless re-pair leaves an existing stream and control channel
  intact until a valid candidate is admitted.
- Physical display-fit/rotation confirmation on the target tablet.
- Sustained CPU/GPU/power measurements for direct, Bridge-only, SGSR/CAS, and
  CfL paths.

Use the state labels strictly: implemented, locally tested, installed, live,
and user-confirmed are different claims.
