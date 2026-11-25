# Night light (Night Shift mirroring)

While a tablet is connected, its Eye comfort shield follows the Mac's Night
Shift exactly: on when Night Shift is active, at the same strength, and off
when Night Shift is off — even if the tablet's own schedule would have been
on. When the session ends, the tablet gets its own settings back.

## Why the tablet has to warm itself

ScreenCaptureKit captures before the display's color transforms, so the
streamed picture stays neutral while the Mac's panels go warm.

## Mac side

- `NightShiftMonitor` polls CoreBrightness' private `CBBlueLightClient`
  (loaded at runtime, never linked) at 1 Hz. The status dictionary's
  `BlueReductionEnabled` value decides on/off; CoreBrightness flips it for a
  manual toggle and at the native custom/solar schedule boundary.
  `AutoBlueReductionEnabled` is **not** the live state — it only means the
  automatic schedule is armed and otherwise keeps the tablet warm all day.
  `getStrength:` gives 0...1. An unreadable probe is **unknown**, not off:
  the mirror does not take ownership before a successful reading, and if the
  probe is lost mid-session it retains the last enforced state instead of
  inventing a Mac-off transition.
- `NightShiftTabletFilter` writes Samsung's `blue_light_filter*` keys through
  `adb shell settings`. The Android app cannot do this itself: those keys are
  outside the public settings table, and the write fails with "You cannot
  change private secure settings" even with `WRITE_SECURE_SETTINGS`.
- `NightShiftMirror` starts on client connect. While connected, a Mac-off
  state actively turns the tablet filter off without discarding the saved
  tablet settings. It releases 10 s after a disconnect, so a Wi-Fi blip does
  not flash the filter, and immediately on Stop or Quit.

Control is conservatively scoped to the streaming client rather than every
adb-visible Samsung device. USB streaming reaches the Mac through adb reverse,
so the client must be the single adb transport carrying both reverse mappings
for the active video/control ports. That rule is transport-independent: a
network-adb reverse tunnel can qualify, while a merely plugged-in Samsung
cannot. Wireless streaming requires a wireless (not USB) adb `IP:port` serial
whose host is the authenticated streaming peer, a normalized model match with
the client's `Build.MODEL` (for example `SM_X800` vs `SM-X800`), and exactly
one match. Hostname or mDNS adb serials fail closed.

Identity is also durable. Once a client is resolved, its `ro.serialno` is
bound for that connection; plugging in a lookalike after the original client
drops cannot inherit control. A reconnect presents a new endpoint proof and is
resolved again. The 10-second disconnect grace is conditional rather than
blindly cancelled: the same physical client keeps its override without a
flash, while snapshots belonging to a tablet left behind by a replacement
client are handed back. Foreign snapshots keep reconciling during the
replacement session if the old tablet is temporarily unreachable. Stop/Quit
and launch recovery use an unconditional release: any device already carrying
a SideTab snapshot is restored even after the client scope is gone. No
matching adb transport (wireless without wireless debugging) means no
mirroring.

## Samsung Eye comfort shield keys (SM-X800, Android 14)

| Key | Meaning |
|---|---|
| `blue_light_filter` | shield on/off |
| `blue_light_filter_opacity` | Custom color-temperature slider, **0...10** |
| `blue_light_filter_scheduled` | "Set schedule" switch |
| `blue_light_filter_type` | 0 Always on, 1 custom times, 2 sunset to sunrise |
| `blue_light_filter_adaptive_mode` | 1 when Samsung Adaptive mode owns color adaptation |

Samsung's BlueLightFilterService (`com.samsung.android.bluelightfilter`)
calls `setNightMode(on, level)` only when "Set schedule" is on. While
mirroring, SideTab therefore sets type 0 + scheduled 1 ("Custom, Always on").
Night Shift strength maps linearly: `round(strength * 10)`.

Settings writes alone are not enough. The service watches the keys only for
10-60 s after it is started, then stops itself; with Samsung's Settings app
closed, writes changed nothing. Like the Settings app, SideTab starts the
exported service after each change:

    am startservice -n com.samsung.android.bluelightfilter/.BlueLightFilterService \
        --ei BLUE_LIGHT_FILTER_SERVICE_TYPE 24   # apply stored mode and level
                                                 # 25 = panel filter off

Success shows `FILTER_ON (Setting) : Always ON` and
`DDI setNightMode : true, index : <level>` in logcat. Both types act only
while scheduled is 1.

While mirroring, Adaptive mode is forced off and the complete Custom/Always-on
state is written; otherwise Samsung's adaptive pipeline can keep owning color
while the Custom opacity keys are changed. The user's adaptive setting is part
of the snapshot and is written back last on release so the adaptive pipeline
sees the complete restored state.

`am startservice` is asynchronous. Restoring therefore always queues a
panel-off phase (filter 0 + type 25) while the mirror's deterministic
Custom/scheduled state is still present — even when the filter key already
reads 0. It then waits for Samsung's own `FILTER_OFF (Setting)` log count to
increase and re-probes the deterministic off state before touching the user's
keys. The log line itself precedes Samsung's scheduled check, so this ordering
is essential: confirmation is evidence only because restoration has not yet
rewritten `scheduled` or Adaptive mode. If execution cannot be confirmed
within a bounded poll (30 attempts at a nominal 100 ms spacing), the snapshot remains pending and the
existing release retry tries again rather than discarding restore state. A
type-24 start is used only for a restored Custom/scheduled shield. It is not
an Adaptive-mode apply path and is a no-op after `scheduled=0`. The user's
settings are saved in UserDefaults
(`SideScreen_nightShiftEyeComfortSnapshots`, by `ro.serialno`) before the
first override, so a quit or crash cannot lose them. If a release finds no
tablet (cable already out, adb slow at quit), it is retried every 15 s and
from the next launch until the saved settings are back on the tablet. While
mirroring, adb/probe/write failures are retried by re-emitting the current
known target every 15 s rather than waiting for the next Night Shift change.

## Opt out

`defaults write com.sidescreen.app SideScreen_exp_nightLight -bool false`
