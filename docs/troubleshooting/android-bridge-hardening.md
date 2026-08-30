# Android ↔ macOS bridge hardening

Status: partial implementation on 2026-08-30. The code and deterministic
tests are saved on the topic branch; installed-app, real USB, real wireless,
and visual tablet checks are still separate evidence gates.

## Issue record

| Symptom | Cause | Current handling | Evidence |
| --- | --- | --- | --- |
| Connect appeared to work, then the tablet was kicked back to idle | StreamClient swallowed setup/read failures and emitted an unqualified disconnect | Setup errors are rethrown; read failures publish a transport reason; cleanup and status callbacks are idempotent | Android unit build/test |
| USB and Wireless could be selected independently of the Mac route | The old listener admitted loopback and LAN connections without a shared mode contract | Mac admits USB only from loopback/ADB-reverse and Wireless only from LAN plus token auth; Android sends a marked mode hello and understands an admission result | Android/Mac protocol tests; live route test pending |
| Checklist showed USB cable connected and Mac server without observing either | Android cannot truthfully infer the Mac-side ADB reverse/listener state without opening a competing stream | Local settings are PASS/FAIL/UNKNOWN; route and Mac state stay UNKNOWN/PENDING until the real Connect path reports socket, admission, display, or frame evidence | Pure checklist tests |
| Wireless showed connected before a display was actually usable | Pairing UI was updated during negotiation and loaded KeyStore state on the main thread | Wireless success is projected only from Streaming; pairing reads/saves/clears are off the main thread; repair has explicit Reconnect and QR recovery paths | Android unit build; device lifecycle pending |
| Android display did not fill the tablet panel | A near-native encoded size was used as the SurfaceView size, creating a centered border when Mac and tablet geometry differed | SurfaceView remains parent-constrained; encoded dimensions remain decoder metadata only | Surface layout unit test; visual device check pending |
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

On the Mac, Start creates the virtual display/capture pipeline; actual frame
encode/send work is admitted only while a client is live. Higher resolution,
HiDPI, FPS, and bitrate increase WindowServer, capture, encoder, bandwidth, or
tablet decode work. Reset Token is local crypto/storage work and does not
restart capture.

## Test and acceptance matrix

Implemented and locally tested:

- Android unit tests: mode-frame encoding/decoding, malformed-frame rejection,
  checklist evidence, SurfaceView layout policy, session ownership, storage
  envelope, frame/keyframe, clock, brightness, and transport-profile tests.
- Mac Swift tests: mode admission, auth, frame pipeline/backpressure,
  display/codec policies, and parallel-safe frame-rate defaults.
- Repository tests: cross-language mode constants, version/identity, workflow
  permissions, manifest boundaries, and frame-trace analysis.

Not yet proven by this branch:

- Installed APK and Mac bundle are not replaced by this topic branch.
- Real SM-X800 USB connect with Mac in USB mode, including unplug/replug.
- Real SM-X800 Wireless connect with Mac in Wireless mode, including WiFi
  loss/reconnect and token rejection.
- Deliberate wrong-mode/wrong-route attempts show the expected user message.
- Physical display-fit/rotation confirmation on the target tablet.
- Sustained CPU/GPU/power measurements for direct, Bridge-only, SGSR/CAS, and
  CfL paths.

Use the state labels strictly: implemented, locally tested, installed, live,
and user-confirmed are different claims.
