# Night light (Night Shift mirroring)

While a tablet is connected, its Eye comfort shield follows the Mac's Night
Shift: on when Night Shift is active, at the same strength. When the session
ends, or Night Shift turns off, the tablet gets its own settings back.

## Why the tablet has to warm itself

ScreenCaptureKit captures before the display's color transforms, so the
streamed picture stays neutral while the Mac's panels go warm.

## Mac side

- `NightShiftMonitor` polls CoreBrightness' private `CBBlueLightClient`
  (loaded at runtime, never linked) at 1 Hz. The status struct's `active` bit
  decides on/off; `getStrength:` gives 0...1. An unreadable probe counts as
  off.
- `NightShiftTabletFilter` writes Samsung's `blue_light_filter*` keys through
  `adb shell settings`. The Android app cannot do this itself: those keys are
  outside the public settings table, and the write fails with "You cannot
  change private secure settings" even with `WRITE_SECURE_SETTINGS`.
- `NightShiftMirror` starts on client connect. It releases 10 s after a
  disconnect, so a Wi-Fi blip does not flash the filter, and immediately on
  Stop or Quit.

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

Samsung's BlueLightFilterService calls `setNightMode(on, level)` only when the
shield is on and "Set schedule" is on. While mirroring, SideTab therefore sets
type 0 + scheduled 1 ("Custom, Always on"), and each level write then shows
`DDI setNightMode : true, index : <level>` in logcat. Night Shift strength
maps linearly: `round(strength * 10)`.

Restoring turns the shield off first, while it is still in that mode, then
puts the user's keys back. Restoring `scheduled=0` first would leave the panel
warm. The user's settings are saved in UserDefaults
(`SideScreen_nightShiftEyeComfortSnapshots`, by `ro.serialno`) before the
first override, so a quit or crash cannot lose them. If a release finds no
tablet (cable already out, adb slow at quit), it is retried every 15 s and
from the next launch until the saved settings are back on the tablet.

## Opt out

`defaults write com.sidescreen.app SideScreen_exp_nightLight -bool false`
