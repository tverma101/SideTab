# Changelog

All notable changes to SideTab will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Session lifecycle
- **The Android display could drop at random while the Mac was still streaming.** The video watchdog retired a working transport on a 6-second read-loop timer whose only evidence was "did the read loop produce anything". Silence is not death: the Mac deliberately sends no frames for an unchanged desktop (ScreenCaptureKit clean-frame suppression), the read loop calls `onFrameReceived` inline and so stalls inside `MediaCodec` under backpressure, and a pong is queued behind video data on the host. Retirement now requires corroborated evidence — a dead read path *and* two consecutive unanswered probes *and* an elapsed budget — and an active read path outranks every timer.
- **Control-channel health was silently controlling video retirement.** `!controlSent` short-circuited the "is video flowing?" guard, so any control hiccup armed the video probe at 1 Hz regardless of the video path. That is what made the disconnect fire *randomly* rather than only on an idle desktop. The control channel no longer has any say in the video arming decision.
- **A 4-second control-pong timeout closed healthy sockets.** A control socket sharing a congested Wi-Fi link with video loses three consecutive 1 Hz pongs to a momentary stall routinely. Raised to 15 s, and the deadline is now armed only after the write returns, so a write blocking on a full send buffer is no longer mistaken for a lost pong.
- **Every control connection reconnected every ~15 s.** When the pong deadline moved to after the write, the probe also started recording that post-write time as its match key, while the packet still carried the pre-write timestamp the host echoes. No pong ever matched: the first probe stayed outstanding, no second ping was sent, and the 15 s timeout closed a healthy socket. The probe now keeps the wire timestamp for matching and the arming time for the deadline. Video pongs also logged `matched=false` unconditionally, because any inbound byte had already retired the probe; that log now reports whether the pong answers the latest probe.
- **A single in-band write exception ended a visibly working stream.** Write failures on a full-duplex socket were treated as fatal with no read-side check, and `requestKeyframe` alone fires from the read loop and from the decoder on every backpressure timeout. Write failures now check whether the read path is still delivering before retiring.
- **Liveness was inferred from video frames only.** A healthy stream between clean frames was indistinguishable from a dead one. Any inbound byte on either socket now counts as proof of life, including display-config re-sends and codec selection.
- **A false positive became a ~58-second visible outage.** The reconnect budget (1 s connect / 2 s handshake) was shorter than the host's 5 s `authenticatedContenderWindow`, so a Wi-Fi blip raced the host's own bookkeeping and every attempt gave up before the host finished deciding. The first reconnect after a live session is now budgeted past that window; later attempts stay short on purpose, to fail over to the next host candidate quickly.
- **A dark-mode or HDR toggle tore the session down.** `configChanges` listed only `orientation|screenSize|screenLayout`, so `density`, `uiMode`, `colorMode`, `smallestScreenSize`, `fontScale`, `keyboardHidden`, `navigation` and `layoutDirection` all recreated the Activity, and `onDestroy` tore the session down mid-stream.
- **The stalest frames were the only ones guaranteed to render.** A `!hasValidLatency` escape hatch short-circuited the wireless freshness policy, so any output older than 2 s — about sixty times the wireless budget — bypassed it and was drawn. That is exactly the decoder-backpressure case where the read loop is also stalling, producing a multi-second-old desktop that reads as a freeze or a disconnect.
- **A stream framing desync was reported as a dead Mac.** An unparseable frame threw a transport error indistinguishable from a dropped socket, so a framing bug was mislabelled "Mac unreachable". It now has its own error type and its own recovery arm.
- **Mac streaming never timed out.** The five-minute timeout did not exist anywhere in the host: `markDisconnected()` was reachable only from the video socket's `.failed`/`.cancelled` handler, the receive loop swallowed clean EOFs, all four control-channel exits just nil'd the socket, and TCP keepalive was never enabled — so a client whose Wi-Fi association dropped left `clientConnected` stuck true for the life of the process. That one stale flag then disabled every periodic host check: `IdleSleepMonitor` never paused capture, the status probe early-returned, the USB checklist never re-probed, and the Paired Devices row stayed a green "Connected". A session that receives nothing for five minutes now ends, stopping the stream and releasing the virtual display. The deadline is measured from bytes the tablet sends, never from frames the Mac pushes, and uses `ContinuousClock` so it survives system sleep — `mach_absolute_time` stops advancing, which is how a five-minute promise would have silently paused overnight.

### Consolidation
- The repository now contains a single macOS implementation. The `MacHost/CaptureTest`, `MacHost/StreamTest`, and `MacHost/test_scstream.swift` harnesses — a second `VideoEncoder`, a second wire server, and a third `SCStreamOutput` conformance, none of which were built, linted, or tested by any script or CI job — have been removed. The deleted server dropped non-keyframes under backpressure, breaking the H.264/HEVC reference chain that the production server explicitly forbids, and its encoder could not emit a frame timestamp at all, so it could not exercise the frame-age telemetry.
- `analyzeNALUnits`, the only Annex-B *reader* in the repository, is preserved as `HEVCNALInspector` in `MacHost/Sources` where it is linted and covered by tests. It also fixes an out-of-bounds trap on short input and names the AUD/EOS/EOB/FD unit types the harness omitted.

### Fixed
- **No video reached the tablet.** The host decided whether an encoded frame was a keyframe by demanding an explicit `NotSync=false` sample attachment, but VideoToolbox never sets one: CoreMedia defines a *missing* `NotSync` key as a sync sample, and every IDR arrives that way. Each keyframe was read as a P-frame, the server's wait-for-first-keyframe gate dropped the entire stream, and the tablet stayed black while the session looked connected. Keyframe detection now follows the CoreMedia contract, and a test drives a real VideoToolbox session to pin it.
- **`swift test` wrote into the live host log.** Tests run as the same user, so their `debugLog` lines landed in `~/Library/Logs/SideScreen/sidescreen.log` interleaved with a real session's diagnostics. A test process now logs to `$TMPDIR/SideScreenTests/Logs/` instead.
- **The tablet's display opened at twice the intended size.** A HiDPI display reported its physical size as if its full pixel count were at 110 PPI, half its real density. macOS picks a new display's default mode from its density, so a 1400×876 Retina display opened as 2800×1752 at 1x: a desktop twice as large with half-size text. macOS then saved that mode and restored it on every connect. The display reports 220 PPI again, and its density is part of its identity, so the saved 1x mode is not reapplied.
- **Capture could not time out.** `SCShareableContent` was raced against a timeout inside a task group, and a Swift task group always waits for every child before returning, so the hang the timeout existed to catch was the one case it could not catch. `startServer` could block forever with no error surfaced. The retry loop that was written to survive this was therefore unreachable.
- **Idle pause/resume left a permanent black screen.** ScreenCaptureKit cannot restart a stopped `SCStream`; the resume path called `startCapture` on one, the error was discarded, and the stall monitor then concluded the display was merely quiet and stopped monitoring. Idle sleep is on by default, so this fired on the first reconnect.
- **HDR conversion could write out of bounds.** The 10-bit pixel-buffer pool was allocated once and never resized, while a codec renegotiation could change the encode size. A reconnect at a larger size wrote a full frame into a smaller allocation — roughly 13.8 MB past the end, per frame.
- **HDR output was about 46x too bright.** The PQ curve was fed a 0..1 signal that its own normalization read as 0..10000 nits, and the result was squeezed into the gamma-luma swing instead of filling the 0..1023 container the VUI declares. A 100-nit white now lands on PQ code 520, where it belongs.
- **HDR frames could tear.** The converter handed a 4-deep rotating pool to VideoToolbox with no completion fence, so a buffer was overwritten while still being encoded.
- **A USB tablet reconnect could never take over.** The contender path cancelled the newly accepted socket instead of the one it meant to evict, so the connection never reached `.ready` — and every rejected contender leaked a socket and a file descriptor.
- **Two wire messages shared tag 11.** The server-to-client `bright` message and the client-to-server decoder-limits message collided. The existing comment claimed old hosts skip unknown types byte-by-byte; a byte skipper consumes 1 of 5 bytes and desyncs by 4. Decoder limits moved to tag 15 on both sides.
- **An un-updated tablet stalled against a new host.** An Android build from before that move still sends decoder limits under tag 11. The host logged the tag and all four payload bytes as five unknown message types, never learned the limits, and the session ended ~20 s later in a reconnect loop. The host now also accepts client-to-server tag 11 as decoder limits (it is inbound-only and never sent, so it cannot collide with `bright`), validates the 7-bit payload, and logs that the tablet is outdated.
- **Every S Pen stroke could be silently dropped.** The host learned stylus support only from the video socket, but the client sends stylus events on the control socket first. A video reconnect erased the flag mid-drag with no client-visible error.
- **Codec negotiation was single-shot.** If the client preamble arrived after the host's 250 ms fallback, the host negotiated HEVC at full resolution to an AVC-only tablet, never sent `codecSelected`, and the client then deferred decoder creation forever — a permanent black screen it attributed to the Mac app's version.
- **A bad port setting could crash the app.** `UInt16(someUserDefaultsInt)` and `UInt16 + 1` at 65535 are both trapping conversions, reachable through the `SideScreen_controlPort` and `SideScreen_port` knobs the code documents. The port read in `DisplaySettings.init` trapped at launch, before any UI. All of them are now validated through one tested resolver.
- **A hung `adb` could brick streaming permanently.** `waitUntilExit()` was called before draining the pipe, and with no timeout, so a child that filled the 64 KB pipe buffer or a wedged adb server hung start, the USB checklist, and adb-reverse repair for the life of the process. All adb calls now drain concurrently under a deadline.
- **A failed start leaked the virtual display.** The error path reset two UI booleans and nothing else, leaving a registered phantom display in Displays that kept re-arranging the user's monitors.
- **The port-reuse setting let a second instance silently steal the port.** A second listener bound the same port with no error and received every connection, so the new instance reported success and rendered a QR that could never be reached.
- **The limited-range YUV conversion applied the luma gain twice**, brightening the whole image by 16% and hard-clipping everything above mid-grey. The colour-range default was also full while the host's default capture is limited, which desaturated every image on decoders that omit the optional key.
- **The decoder could live-lock on a large keyframe.** `KEY_MAX_INPUT_SIZE` was never set, so input buffers were sized for an average frame; an IDR overflowed them, the overflow handler requested another keyframe, and the loop repeated forever.
- **The decoder was published before `start()`**, so the frame path could hand data to a codec that was not yet running, guaranteeing a dropped keyframe at every connect and surface change.
- **Every connect built the decoder twice and kept the slower one.** The host sends the display config twice on connect, and each copy started a background decoder build before the first had published. The second request retired the first build, which already held the surface, so the second build's low-latency configure failed and it fell back to a slower configuration. An identical request is now a no-op while a build is in flight.
- **A rotated pairing token was rejected by the running listener.** "Reset Token" minted a new token and re-rendered the QR, but the listener snapshots its expectation at start, so every re-scan failed. The listener now adopts the new token immediately.
- **The QR could encode `0.0.0.0`** when no routable LAN address existed — a valid-looking, permanently unpairable code. It is no longer rendered at all in that state.
- **A VPN or ULA address could be advertised as the pairing target**, making the UI claim a working LAN configuration the tablet could never route to.
- **A rotating IPv6 privacy address was advertised as the primary host**, breaking every previously paired tablet roughly hourly. Addresses are now ranked by tenure so a newly rotated temporary drops into the fallback list.
- **Codec negotiation could double-fire from two queues**, building two encoders and sending the client two display configs.
- **The dirty-rect gate was a silent no-op.** It decoded the attachment as `[CGRect]` or `[NSValue]`, but the real attachment is an array of `CFDictionary`, so the wireless optimization saved nothing and no counter distinguished "no changes" from "could not tell".
- **The virtual-display safety net re-arranged the user's other monitors.** The display configuration callback only set two origins, and any display left unset is documented as repositioned. It also could promote a sleeping panel into the main slot — reintroducing the lockout it was written to prevent — and could write mirror state permanently, leaving a mirror relationship pointing at a display that no longer exists after logout.
- `getifaddrs` and a synchronous Keychain round trip ran from SwiftUI `body` on every mouse-move invalidation, and the 5-second timer did its work in `.common` run-loop mode during window drags.
- The `DitherPass` amplitude gate was inert at every documented setting and its in-place pass dithered flat regions, contradicting its own contract.
- `CodecLimits` squashed the aspect ratio by up to 0.74% by aligning each axis independently.
- The Annex-B NAL walk had no length validation, so one corrupt length word became a multi-gigabyte out-of-bounds read.
- A forced keyframe was consumed even when the encode failed, stalling the receiver for up to 5 seconds.
- The host frame timestamp is now monotonic; it previously mixed two clocks' opinions about the same frame and could step backwards.
- The in-band touch parser now rejects non-finite and out-of-range coordinates, matching the stylus parser.
- A VPN status toggle now honours `.requiresApproval`, so a registered login item no longer shows as off and re-prompts on every login.
- The debug log moved out of a fixed, unrotated, symlink-followable path in `/tmp` and is now size-capped under the app's own logs directory.
- The Android control-channel pong read 16 bytes for a 17-byte message, stranding a byte and retiring the socket on every pong.
- A socket leaked whenever transport installation failed after the pending-socket field was cleared, up to eight times per session.
- Keystore and shared-preference I/O no longer runs on the main thread during connect, and heavy `MediaCodec` construction no longer stalls the UI.

### Security and maintenance
- Android app data, including Keystore-encrypted pairing tokens, is excluded from cloud backup and device-to-device transfer; legacy plaintext preferences migrate on the next successful load.
- Release APK builds no longer fall back to the debug signing key and fail with an actionable configuration error when release credentials are missing.
- The VSR A/B broadcast hook is debug-only and is not registered by release builds.
- USB helper scripts now forward both the active video (`54321`) and control (`54322`) ports. Documentation no longer promises wireless auto-connect when the current UI requires tapping **Reconnect**.
- Android connections are user initiated: failed or dropped sessions no longer retry indefinitely or resume a saved session on app launch. Tap **Connect** or **Reconnect** when you want another attempt.
- The idle Android checklist no longer probes the Mac every two seconds; Mac availability is learned from an explicit connection attempt.
- Android keyframe requests now run on the serialized control I/O executor, so decoder callbacks cannot disable the dedicated control socket with a main-thread network exception.
- Wireless control connections now require the existing pairing token before accepting touch, ping, or keyframe messages; loopback USB reverse-forwarding remains local-only. Wireless video is still cleartext and should be used only on a trusted network.
- `scripts/backup_android_apks.sh` now preserves all local Android APK outputs and the installed device APK in timestamped, non-overwriting snapshots before further installs.
- APK recovery snapshots remain available locally under `backups/apk/` but are no longer tracked in Git.
- Android now treats a configured data-only USB/ADB cable as connected in the checklist, and the main activity is single-instance so returning from Home cannot leave a hidden streaming activity behind.
- Android keeps the display awake only while a live stream is visible, restores that state when returning to the activity, and no longer relies on a 30-minute partial CPU wake lock.
- Manual Android Disconnect now restores the connection panel, orientation, controls, and idle checklist instead of leaving the streaming UI stuck after the socket closes.
- Android pauses latency pings while backgrounded and keeps an idle dedicated control socket alive, preventing stale multi-second RTT samples and permanent in-band fallback after foregrounding.
- The Android decoder now fences asynchronous input-buffer callbacks across codec recreation, and the first frame arriving during decoder startup requests a fresh sync frame instead of leaving the stream waiting on a P-frame.
- `scripts/install_android.sh` rebuilds the debug APK before installing by default; use `--skip-build` only when intentionally installing an already-built artifact.
- Android install, USB setup, and development scripts now resolve one deterministic ADB binary, preferring Android SDK `platform-tools` over older Homebrew copies; the Mac host uses the same preference for device discovery and reverse forwarding.
- Android's wired port field now rejects malformed and out-of-range values instead of silently connecting to the default port; the accepted ceiling leaves room for its adjacent control port.
- Android bounds received display metadata to supported transform values and a maximum 8K frame area before creating decoder or renderer resources.

### Added
- Samsung S Pen drawing support: stylus contact is detected separately from finger touch, starts a direct stroke immediately, forwards normalized pressure/tilt/orientation, and supports hover-cursor movement plus the S Pen secondary button. The negotiated protocol falls back to legacy touch for older Mac hosts.
- The Mac status-item menu now includes a compact Tablet Brightness slider. Its selected level is persisted while disconnected and queued through the capability-gated control channel until the Android client is ready.

### Fixed
- Fixed an Android startup crash where view binding could not resolve the extracted stream-status overlay include.
- CfL and SGSR renderer failures now release partial EGL/GL state, stop their render loops safely, and keep resource teardown on the owning render thread. CfL also falls back when EGL cannot be made current instead of leaving the decoder blocked on a frame buffer.
- Android now releases the codec and renderer pipeline on wired or wireless disconnect, surface loss, and decoder initialization failure. Decoder setup and stale output callbacks also clean up across codec recreation.
- Wired connection errors now reach the UI instead of being swallowed inside the socket client; USB input validation reports bad ports directly.
- The USB checklist now shows an unchecked Mac server as neutral until Connect tests it, instead of falsely reporting that a running server is unavailable.
- The universal Mac build now uses a separate SwiftPM scratch directory per CPU architecture, so packaging cannot combine stale or mismatched lipo inputs.
- The Mac USB checklist now distinguishes an unauthorized or offline tablet from a missing device, and the latest universal DMG has a stable `dist/current/` path.
- `scripts/package_current.sh` now validates and collects the current Mac DMG and Android debug APK into one manifest-backed version folder, without a duplicate loose Mac app bundle.
- Android cancels in-flight control-socket connects on disconnect or network changes and fences retired retry loops so an old attempt cannot outlive a new session.
- Android now clears pending video/control ping deadlines when the app backgrounds, then probes with fresh timestamps on return; a delayed background pong can no longer close a healthy stream.
- Wireless recovery now allows eight bounded reconnect attempts with capped backoff, so short Wi-Fi interruptions get time to recover before the UI reports a terminal disconnect.
- QR scanning now closes ML Kit resources, releases camera frames when scan setup fails, avoids repeating the same invalid-code toast, and preserves every advertised fallback host in saved pairings.
- Stream callback setup is shared between wired and wireless sessions, keeping their generation checks and cleanup behavior consistent.
- Wired SDR colors: the normal macOS 8-bit capture now uses video-range `420v`, matching the Android hardware decoder's limited-range conversion instead of expanding contrast from full-range `420f`. The legacy `SideScreen_exp_pixelFormat=8bit` full-range value remains available only as an explicit A/B control.
- Wireless recovery: a failed connection now keeps the cached or just-scanned pairing available, presents **Reconnect** as the primary repair action, and keeps QR scanning secondary unless the Mac rejects the pairing token. Manual Disconnect also returns to the paired-idle screen instead of leaving the wireless panel in its previous state; dedicated QR control-port overrides survive the in-session retry path.
- Wireless transport now tries Android's per-network `SocketFactory` first, then the process-default route and legacy `bindSocket` fallback, preserving connectivity across OEM routing implementations.
- Wireless home-network recovery now carries multiple usable LAN addresses in QR/Bonjour data, including bracketed IPv6, and tries the same candidates for video and control. The unproven private-hotspot workaround was removed so recovery never changes the tablet's normal WiFi/Internet route.

### Performance
- Wireless 60-FPS transport no longer waits for the TCP socket to have room for
  an entire encoded frame before admitting the next frame. The sender now uses
  a small headroom floor plus its existing bounded in-flight frame/byte budget,
  preventing a healthy Wi-Fi connection from self-throttling every other frame.
- The Mac wireless capture path now uses a dedicated ordered sample queue and a
  four-frame ScreenCaptureKit queue, while Android limits video read-ahead to
  64 KiB with a 256 KiB socket receive hint. These changes reduce stale buffering
  without changing resolution, codec, bitrate, or color quality.
- ScreenCaptureKit now skips frames whose dirty-rectangle metadata explicitly
  reports no visual changes on USB and wireless. Quiet periods use transport
  pings instead of periodic duplicate encodes, while reconnects still force a
  cached keyframe when one is available. Zero-valued TCP headroom metadata is
  treated as unavailable on routes where that sample is not reliable, while
  the bounded in-flight frame/byte budget remains enforced for wireless.
- Android no longer holds a partial CPU wake lock or keeps the panel awake on
  the connection screen. During any active, visible stream it keeps the panel
  awake; backgrounding the app returns display sleep to Android. Wireless also
  advertises the source cadence to SurfaceFlinger and bounds its receiver frame
  pool so a rare large keyframe cannot retain multi-megabyte buffers
  indefinitely.
- The Mac pauses capture after 15 seconds without a connected tablet in both
  transport modes, then resumes and forces a fresh keyframe on connect. Stopping
  the server drains capture work and releases the encoder and cached IOSurface.
- The Mac uses one ordered capture callback queue for both transports. Hidden,
  disconnected server sessions check ADB status every ten seconds instead of
  every two; hidden live sessions skip status polling.
- The Mac wireless video listener now uses Network.framework's
  throughput-oriented `.bestEffort` class while retaining explicit bounded
  in-flight/freshness pressure. USB remains on `.interactiveVideo`.
- macOS USB status probes now run off the main actor, overlapping ADB repairs are suppressed, and the capture callback latches session flags instead of reading connection preferences on every frame.
- Android's steady-state decoder path keeps the 60-FPS callback handoff bounded without reusing input-buffer indices from a retired codec instance.
- USB install diagnostics now preserve the fresh-build fast path and report the selected ADB binary plus the complete device state when the tablet is not ready, avoiding wasted APK builds and ambiguous connection failures.

### Planned
- Audio streaming
- Multi-touch gestures

---

<a id="0.11.1"></a>
## [0.11.1] - 2026-07-19

Safety and quality-of-life release. Fixes the headless lockout that could force a recovery boot (#39), the remaining random black screen on reconnect (#44), and black screens on tablets whose video decoder can't keep up with high resolutions (#41) — plus display flip for teleprompter setups contributed by @peterdenham (#28).

### Added
- **Horizontal/Vertical flip (#28).** Two new toggles next to Rotation on the Mac mirror the picture left↔right and/or top↕bottom — built for teleprompter rigs. Touch input is mirrored to match. Contributed by @peterdenham. *Requires updating both the Mac app and the Android app*: with an older Android app, enabling flip shows an unflipped picture and temporarily forces landscape until the tablet is updated.
- **Decoder-aware resolution (#41).** The tablet now tells the Mac the maximum size its hardware video decoder can actually handle, and the Mac scales the stream to fit (aspect preserved). High resolutions + HiDPI no longer black-screen on budget tablets — they just stream at the largest size the device can decode. Fully backward compatible in both directions. If decoding still fails, the tablet now shows a clear message naming its decoder limit instead of staying silently black.
- **Hide settings icon (#36).** New toggle in the tablet's streaming settings hides the floating settings button — handy for drawing and teleprompter use. Swipe back to reveal it for a few seconds.
- **Menu bar quick actions.** The Mac menu bar icon now shows live status (stopped / waiting / connected with device name), Start/Stop Streaming, and a USB↔Wireless mode switch — no need to open the settings window. The icon dims while the server is stopped.

### Fixed
- **Headless lockout (#39, severity 0).** After using the tablet as the Mac's only screen, the app could restore the invisible virtual display as the *main* display on the next auto-start — menu bar, dock, and keyboard focus moved to a screen nobody could see, which looked like a completely dead Mac and forced a recovery boot. Three layers of protection now guarantee a physically attached display always owns the main slot: the saved main-slot position is never re-applied while a physical display is online, the invariant is re-asserted on every display-topology change (including hot-plugging a display into a running headless Mac, which now hands the main slot back immediately), and display arrangements are no longer written into WindowServer's permanent preferences.
- **Random black screen on reconnect (#44, follow-up to #40).** Display config and codec negotiation can arrive in either order on reconnect; a decoder created with the wrong codec now recreates itself instead of silently consuming the stream forever. Contributed by @ltminh88.
- **Start button double-trigger.** Rapid double Start (menu bar or settings window) can no longer create two virtual displays or bind the port twice.

### Installation
- **macOS**: Open `SideScreen-0.11.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Requires macOS 13 (Ventura) or later.
- **Android**: Install `SideScreen-0.11.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.11.0"></a>
## [0.11.0] - 2026-06-29

Headless auto-start. The Mac host can launch at login and start streaming automatically, so a Mac with no display of its own can boot up and serve the tablet with nothing to press on the Mac — the tablet's own Connect (USB) / Reconnect (Wireless) button is the only thing you touch. Building on the headless groundwork contributed by @shhrohan (#25), reworked to keep wireless mode and the existing settings UI intact, and to start the server *declaratively at launch* rather than reacting to USB plug/unplug events.

### Added
- **Launch at Login.** Registers the host as a login item (`SMAppService`) so it starts silently in the background after you log in. New toggle in the Settings → "Startup" group.
- **Auto-start streaming on launch + Startup mode.** When enabled, the server starts automatically when the app opens, in the connection mode (USB or Wireless) you choose. The server then stays up and listens; the tablet connects/reconnects whenever, with no action required on the Mac.
- **Self-healing USB bridge.** `adb reverse` is now re-established automatically whenever a device is present but the forward is missing (replug, adb-server restart, …), instead of only on the USB connect edge.

### Notes
- The server lifecycle is no longer tied to USB plug/unplug — it does not auto-stop on disconnect, so the virtual display (and your window layout) persists across tablet reconnects. The tablet's existing Connect / Reconnect buttons remain the connection path; nothing on the Mac needs pressing.
- First-time setup still needs a screen once (to grant Screen Recording permission); afterwards the Mac can run fully headless. For wireless headless use, pin the Mac to a static IP / DHCP reservation — automatic discovery (mDNS) is still planned.

### Installation
- **macOS**: Open `SideScreen-0.11.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Requires macOS 13 (Ventura) or later.
- **Android**: Install `SideScreen-0.11.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.10.1"></a>
## [0.10.1] - 2026-06-12

Wireless connection fix. Several people reported the tablet connecting at the TCP level but the Mac never responding — the loading screen hung forever and only flipped to "Couldn't reach Mac" when the server stopped. This was most common on mobile hotspots and carrier-NAT networks. Contributed by @akashraj9828 (#26, closes #10).

### Fixed
- **Wireless connection hangs in "Connecting…" on many networks.** The Mac host enabled TCP Fast Open on its listener, but the Android client uses standard TCP (no TFO). On networks with middleboxes (mobile hotspot, carrier NAT), the connection's `NWConnection` stayed in `.preparing` and never reached `.ready`, so the auth handshake never ran and the Mac stayed silent at the application layer — even though the TCP handshake itself completed. Removing the Fast Open option lets the connection establish normally. USB was unaffected (loopback has no middleboxes), which is why it always worked. `noDelay` (Nagle's algorithm disabled) — the optimization that actually matters for streaming latency — is kept.

### Installation
- **macOS**: Open `SideScreen-0.10.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Requires macOS 13 (Ventura) or later.
- **Android**: Install `SideScreen-0.10.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.10.0"></a>
## [0.10.0] - 2026-06-12

Compatibility release: H.264 fallback for tablets that have no HEVC decoder (e-ink devices like the Onyx Boox line), macOS 13 Ventura support for older Intel Macs, and a custom-resolution Apply that actually applies.

### Added
- **H.264 fallback for devices without an HEVC decoder.** Side Screen streamed HEVC only, so tablets whose firmware ships no HEVC decoder (e.g. Onyx Boox Nova Air C) connected fine but showed a black screen — frames arrived, nothing could decode them. The Android client now probes `MediaCodecList` once at connect and, when HEVC is missing, advertises it to the Mac, which switches the encoder to H.264 (Main profile) and clamps the encode resolution to the 1920×1088 floor that every AVC hardware decoder meets — preserving aspect ratio, 16-aligned. Devices with HEVC keep streaming HEVC exactly as before; the fallback only activates where today there was nothing. Thanks to Devin Lange for the report and the adb diagnostics that pinned the root cause.
- **macOS 13 (Ventura) support.** The deployment target dropped from macOS 14 to 13, so 2017+ Intel Macs stuck on Ventura can run the host. The binary was already universal (arm64 + x86_64); only one macOS 14-only API stood in the way. App-bundle metadata (`LSMinimumSystemVersion`) now matches. Heads-up: ScreenCaptureKit and the virtual-display private API are less battle-tested on 13 — reports welcome.

### Fixed
- **Custom resolution "Apply" did nothing.** Three stacked bugs: the W/H fields only committed their text when you pressed Return (clicking Apply read stale values, and locale formatting injected grouping separators like "1.920"); nothing listened for resolution changes while the server ran, so even a committed change sat idle until a manual stop/start; and out-of-range values were rejected silently. Now Apply reads exactly what you typed, the server restarts itself (~2 s, the tablet reconnects) whenever the resolution changes mid-run — picker rows included — the applied custom value shows up highlighted in the resolution list, and out-of-range input disables Apply and shows the supported range (640–7680 × 480–4320).

### Notes
- Two new wire-protocol messages (`9` client-is-AVC-only, `10` codec-selected), both strictly opt-in: an old Mac safely ignores type 9 (payload-free by design), and type 10 is only ever sent to clients that asked. Every mixed old/new pairing on HEVC-capable devices behaves byte-identically to 0.9.1. The one combination that still can't stream — AVC-only tablet against an old Mac — now shows "update the Mac app" on the tablet instead of a silent black screen. Update both sides to get the fallback.
- H.264 is a less efficient codec than HEVC; on AVC-only devices expect the clamped resolution (e.g. a 1872×1404 panel streams at 1440×1088) and slightly softer text than an HEVC device would get. That trade buys a working screen on hardware that previously had none.

### Installation
- **macOS**: Open `SideScreen-0.10.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`. Now requires macOS 13 (Ventura) or later — was 14.
- **Android**: Install `SideScreen-0.10.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.9.1"></a>
## [0.9.1] - 2026-05-18

Hotfix for a "cursor trail" / ghost-cursor artifact visible on shaky WiFi (e.g. iPhone hotspot) under 0.9.0. Android-only — Mac host is unchanged.

### Fixed
- **Cursor trail / ghost cursors on WiFi jitter.** When a brief WiFi burst saturated MediaCodec's input pool on Android, the decoder kept receiving P-frames whose reference state had quietly diverged from the encoder's. The mismatch painted ghost cursors at old positions until the next scheduled keyframe arrived (~1 s later). The client now **force-requests a fresh keyframe** the moment the input pool exhausts, bypassing the 1 s / 500 ms / 500 ms throttle chain that was holding recovery back — the reference rebuilds in ~150 ms instead. The pipeline keeps feeding through the recovery so the cursor stays live (a brief trail is visible while the keyframe is in flight, then it clears). A new 200 ms throttle on forced requests prevents the host being keyframe-flooded under sustained congestion.

### Installation
- **macOS**: 0.9.0 DMG works — no Mac changes in this release. Otherwise install `SideScreen-0.9.1-mac-universal.dmg` and run `sudo xattr -cr /Applications/SideScreen.app` if Gatekeeper complains.
- **Android**: Install `SideScreen-0.9.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.9.0"></a>
## [0.9.0] - 2026-05-18

Stream resilience pass — faster recovery after backgrounding/reconnect, less lag pile-up on rapidly changing content, and two latent bugs squashed in the wire layer. Contributed by @luisdavim (#16, relates to #13).

### Added
- **Keyframe tracking and recovery**. The Android client now parses per-frame metadata from the Mac host (keyframe flag + capture timestamp), waits for a fresh keyframe before feeding the decoder after startup or codec error, and explicitly requests a keyframe from the host on demand. Returning to Side Screen from home / multi-task now recovers in ~50–100 ms instead of staying garbled until the next scheduled keyframe (~1 s). An opt-in handshake message keeps older clients on the legacy frame format so mixed versions still work.
- **Stale decoder-output drop**. When the decoder's output queue piles up under heavy scenes (fast terminal scroll, large window scroll, etc.), frames whose decoder-pipeline latency exceeds 100 ms are dropped rather than rendered. Cursor and touch feel stay live instead of slowly trailing reality.

### Fixed
- **Touch thread priority was being set on the wrong thread.** `Executors.newSingleThreadExecutor` runs the thread factory on the caller, so the `Process.setThreadPriority(THREAD_PRIORITY_DISPLAY)` call inside the factory was elevating whichever thread happened to call `connect()` instead of `TouchThread` itself. The priority call now runs from inside the worker, so touch handling actually gets the boost under CPU pressure.
- **Coalesced messages on the Mac host could silently lose touch/ping events.** The Mac input loop read up to 22 bytes per receive and processed only the first message; when TCP combined a touch frame plus a ping into one segment, the trailing message was dropped. Replaced with a buffered parser that consumes one message at a time and keeps the rest for the next round.
- **Async diagnostic log writes.** `DiagLog` no longer blocks on file I/O on the calling thread — writes run on a dedicated single-thread executor. Helps on devices where the previous synchronous `appendText` showed up in input latency profiles.

### Notes
- This release adds three new wire-protocol message types (`6` video-frame-with-metadata, `7` keyframe-request, `8` client-supports-metadata) but keeps the legacy type `0` path. Mixed pairs are safe: a new Android client + old Mac host falls back to legacy frames; a new Mac host + old Android client never sees the new types because the client doesn't advertise capability. Update both sides to get the recovery benefits.

### Installation
- **macOS**: Open `SideScreen-0.9.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.9.0-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.8.1"></a>
## [0.8.1] - 2026-05-12

Small fix on top of the 0.8.0 wireless release. Wireless mode (QR pairing, auto-reconnect, paired-devices management) and everything else from 0.8.0 stay the same — this patch only fixes a UI bug in the Mac Status section.

### Fixed
- **Info tooltips next to status rows now show their hint text.** Clicking the `ⓘ` icon next to a status row previously opened an empty horizontal bar instead of the explanation. Now it pops up the hint properly (e.g. what "ADB reverse" or "Listening on" actually mean).

### Installation
- **macOS**: Open `SideScreen-0.8.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: APK from 0.8.0 still works — no Android changes in this release. Otherwise install `SideScreen-0.8.1-android.apk` (enable "Unknown sources" if needed).

---

<a id="0.8.0"></a>
## [0.8.0] - 2026-05-09

Wireless connection mode — Android client can now connect to the Mac host over WiFi LAN via one-time QR pairing, no USB cable required. USB mode unchanged and remains the default.

### Added
- **Wireless mode** — pair via QR scan, auto-reconnect on every launch, secure by token. Built on the same short-GOP encoder pipeline that landed in 0.7.0, so quality matches USB whenever your WiFi is healthy.
- **Mode-aware status checklist** — Mac status section now adapts to your connection mode. USB mode tells you when ADB is missing (with the `brew install` command right there). Wireless mode shows your WiFi state and listening address.
- **Paired devices on Mac** — see every tablet you've paired with, forget devices individually, or rotate the auth token to revoke access for all of them at once.

### Changed
- Android connection screen now has a top-level **USB / Wireless** segmented switcher. Manual host/port entry stays in the USB tab unchanged.
- **Default port changed from 8888 to 54321** (8888 collides with HP printers, Splunk, Jupyter, and many dev tools — fresh installs now default to 54321; existing users keep their saved value).
- Status section rows now have an `info.circle` icon next to each label — hover to see what the row means and how to fix it.

### Notes
- Wireless adds 10–50 ms of latency depending on WiFi quality. For text/web/video it's not noticeable. For drawing precision or fast-paced gaming, USB still wins.
- The token authorizing wireless connections is generated on first launch and stored locally — anyone with your Mac's QR can pair, so don't share it broadcast-style. "Reset Token" on Mac revokes all paired devices.

### Installation
- **macOS**: Open `SideScreen-0.8.0-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged"/"cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.8.0-android.apk` (enable "Unknown sources" if needed). Wireless mode requires camera permission to scan the pairing QR.
- **First wireless pairing**: open Side Screen on Mac → toggle to Wireless tab → scan the displayed QR with the Android app's Wireless tab.

---

<a id="0.7.1"></a>
## [0.7.1] - 2026-05-06

Hotfix — Mac app was being quarantined as malware by macOS XProtect on install.

### Fixed
- **Mac app flagged as virus and auto-moved to Trash on 0.7.0**: the new "Reset Permission" helper from #8 spawned `tccutil reset ScreenCapture <bundle-id>` from inside the app. This is the exact pattern XProtect's YARA rules use to detect TCC-bypass malware (Atomic Stealer / Cthulhu Stealer family). Combined with the existing ad-hoc signature and `disable-library-validation` / `allow-unsigned-executable-memory` entitlements, the binary scored high enough to be quarantined automatically. The auto-reset feature has been removed; stale-TCC handling is back to 0.6.8 behavior — users who hit it after a reinstall need to remove the SideScreen entry manually under System Settings → Privacy & Security → Screen Recording. All other 0.7.0 improvements (short-GOP encoding, instant decode handshake, default 60 Hz, touch parsing gate, Arrange Displays shortcut, decoder latency log) are preserved.

### Installation
- **macOS**: Open `SideScreen-0.7.1-mac-universal.dmg`, drag SideScreen to Applications. If Gatekeeper says "damaged" or "cannot be opened": `sudo xattr -cr /Applications/SideScreen.app`
- **Android**: Install `SideScreen-0.7.1-android.apk` (enable "Unknown sources" if needed)
- **If you installed 0.7.0 and the app was moved to Trash by macOS**: empty Trash first, then download 0.7.1 fresh — the 0.7.0 binary was rejected by XProtect, redownloading the same file won't help. After installing 0.7.1, run the `xattr -cr` command above.

---

<a id="0.7.0"></a>
## [0.7.0] - 2026-05-05

User-experience improvements (permission recovery, display arrangement) and pipeline performance work to reduce input lag on high-resolution tablets.

### Fixed
- **Stuck Screen Recording permission after reinstall** (#8): when macOS holds onto a stale TCC entry from a previous SideScreen install, `CGRequestScreenCaptureAccess()` no-ops silently and the user is locked out. The Status section now detects this state (preflight returns false despite a previous successful grant), surfaces a "Permission stuck" banner, and offers a one-click "Reset Permission" button that runs `tccutil reset ScreenCapture com.sidescreen.app`. If the spawn fails, a fallback banner shows the exact command with a Copy button.
- **Input lag on dynamic content / high-res tablets** (#13): the encoder previously used all-intra (every frame a keyframe), producing 3-5x more data per frame than necessary. This saturated tablet decode/compose pipelines at high panel resolutions and starved Mac WindowServer rendering when capturing fast-changing content. Switched to short-GOP IPP encoding (1 keyframe per second, P-frames in between), which keeps frame-loss recovery within 1 second over reliable USB-C TCP while dramatically lowering per-frame work end-to-end.
- **Touch parsing wasted CPU when touch was disabled**: incoming touch frames from the client were parsed and dispatched to the main queue even when host-side touch control was off; only the `guard` in the handler discarded them. Touch frames now drop early without parsing or dispatch when `touchEnabled` is off; ping/pong continues unaffected.
- **Slow first frame after client connects on idle screen**: with short-GOP encoding, a client connecting during a static screen would wait up to a full second for the next scheduled keyframe before its decoder could start. The host now forces an IDR keyframe the moment a client appears, replays the last cached pixel buffer if capture is currently idle, and drops orphan P-frames at the streaming server until that first keyframe is sent — so a fresh decoder always starts on a sync frame. (Cherry-picked from #15 — thanks to @luisdavim for the contribution and @busybox11 for testing.)

### Changed
- **Default refresh rate is now 60 Hz** for new installs (was 120 Hz). 120 fps stream on a 120 Hz tablet leaves zero VSync headroom — any pipeline jitter immediately queues frames. 60 fps gives 2:1 headroom on 120 Hz panels and a 16.7 ms budget on 60 Hz panels. Existing users keep their saved value; users can still opt back to 120 from settings.
- **Display Configuration UI**: refresh-rate selector moved into its own section, full-width custom buttons replace the native segmented picker, and the resolution list height now adapts to whether "Show all" is on.

### Added
- **"Arrange Displays…" shortcut** (#12) in the Display Configuration section. Opens System Settings → Displays directly on the arrangement pane.
- **Decoder pipeline latency log** on the Android client. Every 60 output frames, DiagLog records average/max decoder input-to-output latency plus available input buffer count, so users reporting lag can attach a log that pinpoints whether the bottleneck is decoder queuing, compose/present, or upstream Mac.

---

<a id="0.6.8"></a>
## [0.6.8] - 2026-03-18

Bug fixes — connection reliability and stream stability.

### Fixed
- **ADB race condition on first connect**: `setupADBReverse()` now completes before the streaming server starts. Previously, the server could begin listening before the ADB tunnel was established, causing the tablet to show "Mac Server Running" in red on first install. Includes automatic retry (up to 3×) to handle first-time USB authorization delays.
- **SCStream false-positive restart on idle screen**: When the display was idle (no content changes), macOS stops delivering frames as an optimization. The frame flow monitor incorrectly treated this as a stream crash and triggered unnecessary restarts, eventually falling back to CGDisplayStream. The monitor now sends a keepalive frame from the last captured buffer instead of restarting. Real SCStream errors are still handled via the error delegate.

---

<a id="0.6.5"></a>
## [0.6.5] - 2026-03-17

HiDPI support and Universal Binary.

### Added
- **HiDPI / Retina mode**: Virtual display now supports HiDPI scaling. macOS renders at 2× physical pixels for sharp, Retina-quality output — even at lower logical resolutions (e.g. choose 1280×800 logical on a 2K tablet for comfortable UI size with full sharpness).
- **Universal Binary**: Mac app now ships as a Universal Binary (arm64 + x86_64), supporting both Apple Silicon and Intel Macs natively.

---

<a id="0.6.2"></a>
## [0.6.2] - 2026-03-17

Universal Binary build system.

### Changed
- Build pipeline updated to produce Universal Binary (arm64 + x86_64).

---

<a id="0.5.2"></a>
## [0.5.2] - 2026-02-21

Documentation update — ADB prerequisite instructions.

### Added
- ADB installation guide in README and website for users who don't have `adb` installed (Homebrew + `android-platform-tools`)
- Clarified that the Mac app requires `adb` to show "Running" status

### Website
- Added ADB prerequisite note to download section

---

<a id="0.2.3"></a>
## [0.2.3] - 2026-02-19

Packaging and documentation fixes.

### Fixed
- Ad-hoc code signing for macOS DMG to reduce Gatekeeper issues
- Gatekeeper workaround (`xattr -cr`) added to website, README, and release notes
- Removed outdated `TAASD` folder references from README and CONTRIBUTING
- Simplified installation guide — users download from GitHub Releases instead of building from source
- Removed redundant terminal code block from website "How It Works" section

---

<a id="0.2.2"></a>
## [0.2.2] - 2026-02-19

Bug fixes and UX improvements for website and DMG installer.

### Fixed
- DMG installer now includes Applications folder shortcut for drag-and-drop installation
- Theme toggle button vertically centered in website header
- Hero action buttons no longer overlap with stats section above
- Removed outdated `adb reverse` manual instructions — Mac app handles port forwarding automatically

### Improved
- Faster scroll-in animations (0.6s → 0.3s) for snappier website experience
- Updated website FAQ and README to reflect automatic ADB setup

---

<a id="1.1.0"></a>
## [1.1.0] - 2026-02-19

Performance overhaul targeting sub-30ms end-to-end latency.

### Performance Improvements
- SCStream `queueDepth` optimization (-33ms worst-case capture latency)
- Async MediaCodec API with Choreographer vsync alignment on Android
- Pipeline decoupling: capture, encode, and send stages now run independently
- Timestamp accuracy fixes on both macOS and Android
- TCP_NODELAY and BufferedInputStream optimizations for network layer
- Touch path latency reduction (removed verbose logging from hot path)

### Developer Experience
- SwiftLint integration for macOS codebase
- ktlint integration for Android codebase
- GitHub Actions CI/CD for automated builds and lint checks
- Professional README with badges, hero section, and structured docs

### Website
- Updated performance claims to reflect <30ms latency target
- Added hero stats section with latency, FPS, and codec info
- Placeholder image instructions for all screenshot locations

---

<a id="1.0.0"></a>
## [1.0.0] - 2025-12-27

Initial public release of Side Screen.

### Features

#### macOS Host
- Virtual display creation using CGVirtualDisplay API
- Screen capture with ScreenCaptureKit
- H.265/HEVC hardware encoding via VideoToolbox
- TCP streaming server (port 8888)
- Settings window with Apple design language
  - Resolution selection (1920x1200, 1920x1080, custom)
  - Frame rate options (30, 60, 90, 120 FPS)
  - Bitrate control (10-50 Mbps)
  - Quality presets (Low, Medium, High)
- Gaming Boost mode for optimized low-latency streaming
- Menu bar integration with real-time performance stats

#### Android Client
- H.265/HEVC hardware decoding via MediaCodec
- TCP client with automatic reconnection
- Full-screen video rendering
- Touch input with prediction for latency compensation
- Floating draggable settings button
- Real-time stats overlay (FPS, bitrate, resolution)
- Performance mode for sustained CPU/GPU performance
- Device rotation support
- Material Design 3 UI

### Technical Highlights
- Hardware-accelerated video pipeline on both platforms
- TCP_NODELAY for minimum network latency
- Frame dropping for frames older than 50ms
- Input prediction using linear extrapolation
- High-priority threads for display operations
- Choreographer-based vsync alignment on Android

---

## Version History Format

Each release follows this format:

```
## [Version] - YYYY-MM-DD

### New Features
- Feature descriptions

### Improvements
- Performance and UX improvements

### Bug Fixes
- Bug fix descriptions

### Breaking Changes
- Any breaking changes (if applicable)
```

---

[Unreleased]: https://github.com/tverma101/SideTab/compare/0.6.8...HEAD
[0.6.8]: https://github.com/tverma101/SideTab/compare/0.6.5...0.6.8
[0.6.5]: https://github.com/tverma101/SideTab/compare/0.6.2...0.6.5
[0.6.2]: https://github.com/tverma101/SideTab/compare/0.5.2...0.6.2
[0.5.2]: https://github.com/tverma101/SideTab/compare/0.2.3...0.5.2
[0.2.3]: https://github.com/tverma101/SideTab/compare/0.2.2...0.2.3
[0.2.2]: https://github.com/tverma101/SideTab/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/tverma101/SideTab/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/tverma101/SideTab/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/tverma101/SideTab/releases/tag/0.1.0
