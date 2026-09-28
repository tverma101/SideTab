# Wired stream color range

The USB SDR stream uses 8-bit video-range NV12 (`420v`) in both ScreenCaptureKit and the CGDisplayStream fallback. The Android hardware decoder and compositor on the tested Samsung tablet expand this range to the display range. Experimental HDR conversion still receives full-range `420f` input, and wireless capture retains its prior format.

## Regression and fix

The previous USB stream sent full-range `420f`. On the Samsung SM-X800, screenshots of the decoded stream matched a second, unwanted video-range expansion: the dark end of a 0–255 ramp clipped to black and the upper end clipped to white. The old APK and the rebuilt APK produced identical pixels, confirming the mismatch was in the shared Mac-to-Android stream path.

Using video-range capture and mapping the built-in test patterns to video range corrected the live wired stream. Center-pixel measurements from tablet screenshots:

| Pattern | Previous mean / maximum channel error | Fixed mean / maximum error |
| --- | ---: | ---: |
| 24-patch color chart | 4.78 / 19 | 0.40 / 3 |
| Full 0–255 gradient | 8.24 / 17 | 0.18 / 1 |
| Dark 0–64 gradient | 10.71 / 16 | 0.22 / 1 |

These are screenshots of this tablet and are not a substitute for checking another device's panel. The SDR conversion has no per-frame CPU pass; the capture API outputs the required pixel range.

## Regression checks

`MacHost/Tests/SideScreenTests/WiredColorRangeTests.swift` checks the wired/wireless/HDR pixel-format choices, full-to-video-range sample conversion, and actual chart/gradient samples written to a pixel buffer. Run `cd MacHost && swift test --jobs 4`.

For a physical USB stream, connect the tablet, start the Mac host, and capture each built-in pattern with `adb exec-out screencap -p`. `scripts/check_wired_color.py` requires `ffmpeg` and returns a failing exit status if the old range expansion returns:

```bash
defaults write com.sidescreen.app SideScreen_exp_pattern -string color
adb exec-out screencap -p > /tmp/sidescreen-color.png
python3 scripts/check_wired_color.py color /tmp/sidescreen-color.png

defaults write com.sidescreen.app SideScreen_exp_pattern -string gradient
adb exec-out screencap -p > /tmp/sidescreen-gradient.png
python3 scripts/check_wired_color.py gradient /tmp/sidescreen-gradient.png

defaults write com.sidescreen.app SideScreen_exp_pattern -string lowramp
adb exec-out screencap -p > /tmp/sidescreen-lowramp.png
python3 scripts/check_wired_color.py lowramp /tmp/sidescreen-lowramp.png

defaults delete com.sidescreen.app SideScreen_exp_pattern
```

Give the stream a few seconds to show each newly selected static pattern before capturing. The checker samples patch centers and ramp points, allowing small codec rounding differences. Clear the pattern preference even if a check fails.
