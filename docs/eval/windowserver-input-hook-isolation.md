# WindowServer input-hook isolation

Tracking issue: #29. Follow-up implementation issue: #30.

## Purpose

Do not attribute the current ~43% WindowServer W0 result to `CGVirtualDisplay`, ScreenCaptureKit, or SideScreen's input hooks until they are isolated independently on the same installed build.

The current source has two relevant global-observation systems:

- `NativeBrightnessController`: HID `CGEventTap` plus global AppKit monitors.
- `AdaptiveRefreshController`: global AppKit monitor for key, mouse-move/down/drag, and scroll events.

The existing host contention sampler records process CPU but does not by itself prove which of those components are active.

## Identity receipt

Before every run record:

```text
source_sha=
installed_path=
cdhash=
virtual_display_active=
virtual_display_refresh_hz=
sck_active=
brightness_hooks_active=
adaptive_refresh_enabled=
adaptive_global_input_monitor_active=
client_connected=
workload=
```

Do not compare runs built from different source snapshots or installed bundles.

## Matrix

Run every state for at least 60 seconds after settling. Repeat three times if the result is close enough to matter.

| ID | Virtual display | SCK | Brightness hooks | Adaptive input monitor | Purpose |
|---|---|---|---|---|---|
| A | off | off | off | off | macOS baseline |
| B | on | off | off | off | pure virtual-display floor |
| C | on | off | on | off | brightness hook delta |
| D | on | off | off | on | adaptive input-monitor delta |
| E | on | on | off | off | SCK delta |
| F | on | on | on | on | current all-on behavior |

Repeat B/E/F at both 60 Hz and 120 Hz. Keep resolution/HiDPI/layout identical.

For A-F run two activity profiles:

1. `static`: hands off the Mac.
2. `physical-input-storm`: continuous mouse movement + scroll on the physical Mac display, not on SideScreen.

The second profile matters because SideScreen currently filters physical-display pointer events only after the global monitor has already received them.

## Existing toggles

Brightness interception can currently be disabled for an A/B with:

```bash
defaults write com.sidescreen.app SideScreen_brightnessKeys -bool false
```

Restore normal behavior with:

```bash
defaults delete com.sidescreen.app SideScreen_brightnessKeys
```

Adaptive refresh can currently be disabled as a coarse control with:

```bash
defaults write com.sidescreen.app SideScreen_adaptiveRefresh -bool false
```

Restore default-on behavior with:

```bash
defaults delete com.sidescreen.app SideScreen_adaptiveRefresh
```

This is **not** sufficient to isolate the adaptive global monitor from the adaptive SCK policy. If #29 needs a clean D/E split, add a temporary experiment-only source knob that disables only `installInputMonitor()` while leaving adaptive capture policy intact. Do not ship that knob as a permanent user setting.

## WindowServer stack capture

During every high-CPU state preserve a stack sample in the run directory:

```bash
WS_PID="$(pgrep -x WindowServer | head -n 1)"
sample "$WS_PID" 10 -file windowserver.sample.txt
```

Look for event-tap/event-vector handling when input hooks are enabled. Private symbol spelling can change between macOS builds; record the actual stacks instead of asserting one exact symbol name.

## Measurements

At minimum record:

- WindowServer CPU p50/p95/max
- SideScreen CPU p50/p95/max
- total CPU
- SCK callback count/cadence
- virtual display refresh
- capture active/stopped
- client connected/disconnected
- `sample WindowServer` stack

For active-stream runs also collect #27/#15 cadence data. Specifically compare whether 40-55 ms host-side frame gaps correlate with high WindowServer/event-hook states.

## Decision table

### Hooks dominate
If B is near baseline but C/D/F jump materially, #30 becomes the first implementation target. Re-run #3 after removing the hook tax.

### Virtual display dominates
If B alone is hot and 120 is materially worse than 60, #3 owns the next implementation experiment.

### ScreenCaptureKit dominates
If B is cool and E jumps, #20/SCK capture architecture becomes primary.

### Costs stack
Quantify each delta independently. Do not accept a single all-on number as attribution.

## Cleanup

After testing, restore all experiment defaults and confirm the installed normal mode still launches with the expected user configuration. No hosted GitHub Actions are part of this acceptance path.
