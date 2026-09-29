# HiDPI tablet display opened at twice the intended size (2026-09-29)

## Symptom

With `SideScreen_resolution = 1400x876` and `SideScreen_hiDPI = 1`, the SideTab
display came up as a 2800×1752 desktop at 1x instead of 1400×876 Retina. The
tablet showed a desktop twice the intended size, with half-size text, and it
never switched to the Retina mode on its own. The stream itself was fine: it was
2800×1752, the tablet's native size, in both cases.

## Evidence

- `system_profiler SPDisplaysDataType`: `SideTab: Resolution 2800 x 1752, UI
  Looks like: 2800 x 1752`. The Mac's built-in panel read `Retina`.
- `CGDisplayCopyAllDisplayModes` on the live display listed `1400x876 px=2800x1752`
  as available, but the current mode was `2800x1752 px=2800x1752`.
- `CGDisplayScreenSize` reported 646×404 mm, which is 110 PPI at 2800 pixels.
- Host log: `SCStream frame geometry: … contentScale=1, scaleFactor=1`.
- `~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist`, last
  written 2026-09-24, held SideTab entries at `1400x876 Scale 2`.
  `/Library/Preferences/com.apple.windowserver.displays.plist` held the current
  display's UUID at `2800x1752 Scale 1` in five display sets.

## Root cause

Commit `5d83719` (2026-09-25 audit) changed two things in
`VirtualDisplayManager.createDisplay`:

1. **Density.** It set the descriptor's physical size to the *pixel* count at
   110 PPI for every display. The previous code used 220 PPI for HiDPI and 110
   PPI otherwise. The audit's comment said both branches "emitted an identical
   rect", which is only true for the same *logical* size. For a HiDPI display it
   halved the density.
2. **Identity.** It replaced the constant serial `0x0001` with a hash of the
   configuration. macOS keys its saved display state on (vendor, product,
   serial), so every SideTab display became a monitor macOS had never seen.

macOS chooses a new display's default mode from its density. At 110 PPI it
chose 2800×1752 at 1x, and then saved that choice for the new identity.

Throwaway `CGVirtualDisplay` probes on macOS 27, each with a never-used serial
and the app's own two-mode list, showed:

| Density | Selected mode |
| --- | --- |
| 220 PPI (323×202 mm) | 1400×876 points, 2800×1752 pixels |
| 110 PPI (646×404 mm) | 2800×1752 points, 2800×1752 pixels |

A second probe created a display at 110 PPI, released it, and re-created the
same serial at 220 PPI. It came back at 1x. **A saved mode outlives a density
fix**, so restoring the density alone would not have repaired this Mac.

## Fix

- `VirtualDisplayLimits.Geometry.sizeInMillimeters` is the logical desktop at
  110 points per inch. A HiDPI display packs twice the pixels into the same
  size, so it reports 220 PPI.
- `VirtualDisplaySerial.Seed` includes `pixelsPerInch`. The corrected display
  is a new identity and does not inherit the 1x mode saved since the audit. A
  mode the user later picks in System Settings is still remembered, because the
  serial stays stable for a configuration.
- The creation line now goes to the debug log with its PPI, and
  `verifyDisplayRegistered` logs `Virtual display mode selected: <points>
  points, <pixels> pixels`. A mismatch with the requested size is visible in
  the log without extra tools.

## Validation

- `VirtualDisplayManagerTests`: `testHiDPIReportsRetinaDensity`,
  `testHiDPIKeepsThePhysicalSizeOfTheLogicalDesktop` and
  `testSerialChangesWithDensity`. All 236 host tests pass.
- Live, on the rebuilt host from `local/install-2026-09-29`:
  - `Virtual display created: 1400x876 HiDPI (physical 2800x1752) @ 120.0Hz,
    220 PPI`;
  - `Virtual display mode selected: 1400x876 points, 2800x1752 pixels`;
  - `system_profiler`: `UI Looks like: 1400 x 876 @ 120.00Hz`;
  - `SCStream frame geometry: buffer=2800x1752 … scaleFactor=2`;
  - the SM-X800 showed the Mac desktop at Retina scale, with
    `Surface mapping: 1:1 stream=2800x1752 panel=2800x1752`.

## Residual gaps and revalidation triggers

- Only 1400×876 HiDPI and 2800×1752 at 1x were measured. Other logical sizes
  were not probed live.
- The probes left a few unused entries for vendor `0xEEEF` in the WindowServer
  display plists. They are inert.
- Re-check `Virtual display mode selected` after any change to the descriptor,
  the mode list, or the serial seed. Any change to density or identity makes
  macOS forget the mode it saved for SideTab, once. The app restores its own
  saved position, so the arrangement survives.
