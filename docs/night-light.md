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
  `getStrength:` gives 0...1. An unreadable probe counts as off.
- `NightShiftTabletFilter` writes Samsung's `blue_light_filter*` keys through
  `adb shell settings`. The Android app cannot do this itself: those keys are
  outside the public settings table, and the write fails with "You cannot
  change private secure settings" even with `WRITE_SECURE_SETTINGS`.
- `NightShiftMirror` starts on client connect. While connected, a Mac-off
  state actively turns the tablet filter off without discarding the saved
  tablet settings. It releases 10 s after a disconnect, so a Wi-Fi blip does
  not flash the filter, and immediately on Stop or Quit.

Only adb devices with SideTab installed and Samsung's keys present are
touched. No adb transport (wireless without wireless debugging) means no
mirroring.

## Samsung Eye comfort shield keys (SM-X800, Android 14)

| Key | Meaning |
|---|---|
| `blue_light_filter` | shield on/off |
| `blue_light_filter_opacity` | Custom color-temperature slider, **0...10** |
| `blue_light_filter_scheduled` | "Set schedule" switch |
| `blue_light_filter_type` | 0 Always on, 1 custom times, 2 sunset to sunrise |

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

Restoring therefore turns the panel off (filter 0 + type 25) while the mirror's
schedule is still in place, waits 0.5 s, then puts the user's keys back, ending
with a type-24 start if their own shield was on. The user's settings are saved in UserDefaults
(`SideScreen_nightShiftEyeComfortSnapshots`, by `ro.serialno`) before the
first override, so a quit or crash cannot lose them. If a release finds no
tablet (cable already out, adb slow at quit), it is retried every 15 s and
from the next launch until the saved settings are back on the tablet.

## Opt out

`defaults write com.sidescreen.app SideScreen_exp_nightLight -bool false`
