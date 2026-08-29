# Android client hardening

Parent: #44

SideScreen's Android decoder/rendering core is already useful. The hardening work targets the application shell around it: ownership, lifecycle, security, and testability.

## Confirmed architecture debt

On the authoritative eval baseline, `MainActivity` directly coordinates session state, transport callbacks, decoder/renderers, Surface lifecycle, presentation/brightness, touch, timers/checklist, pairing UI, and diagnostics. `WirelessTabController` also maintains a separate connection-looking UI state machine even though #23's `SessionController` is intended to be authoritative.

The problem is not file length by itself. A streaming client can legitimately have large platform adapters. The blocker is overlapping ownership and asynchronous lifecycle boundaries.

## Target ownership

```text
Activity / views
    │ user intents + Surface availability
    ▼
AndroidSessionRuntime (#45)
    ├── authoritative SessionController (#23)
    ├── transport adapter (V1 now, #34 later)
    ├── RenderSession (#47)
    ├── PresentationController (#24/#26/#41)
    ├── lifecycle/reconnect (#39-#43)
    └── typed non-secret config (#50)

UI projection (#46) reads authoritative state; it does not invent connection state.
```

## Work order

1. Foundation safety: #48 pairing at-rest/backup protection, #49 release/failure hygiene, QR resource lifecycle.
2. #45 move live session/runtime ownership out of `MainActivity`.
3. #46 collapse USB/wireless UI onto one immutable authoritative model.
4. #47 make Surface/MediaCodec/SGSR/CfL ownership transactional and generation-bound.
5. Integrate #39-#43 suspend/sleep/wake reconnect through the runtime rather than Activity callbacks.
6. #50 typed/migrated app-owned settings.
7. #51 target-device torture becomes the merge gate.

## Upstream/reference rule

`moonlight-stream/moonlight-android` is a valuable mature Android streaming reference, but it is GPL-3.0 while SideScreen is MIT. Treat Moonlight code as architecture/reference only unless a separately compatible source/license is identified. Do not copy GPL implementation into this repository.

## Non-regression gates

Android refactoring is not allowed to trade away the validated display path. Preserve and re-measure:
- wired 2800x1752 direct MediaCodec quality;
- frame freshness/cadence and touch latency;
- brightness/presentation ownership;
- no duplicate transport/decoder/render sessions;
- wireless 60 FPS experiments from #38;
- first fresh Surface-rendered frame after reconnect.

Every major runtime slice must carry an exact APK/device/session receipt on SM-X800 before leaving Draft.
