# AirPlay display receiver

> **Discontinued (2026-10-14).** The AirPlay route is disabled. The Android
> client no longer surfaces an AirPlay entry point, the Mac Settings window no
> longer links to Displays for it, and `build_android.sh` / `install_android.sh`
> / `package_current.sh` skip the companion unless `SIDESCREEN_WITH_AIRPLAY=1`
> explicitly opts in. The pinned submodule, patch, and build script below are
> kept for archival purposes.

SideTab's Android client offers AirPlay as a separate companion app. The
companion is built from the maintained
[`jqssun/android-airplay-server`](https://github.com/jqssun/android-airplay-server)
repository, pinned at tag `v0.0.31` / commit
`c8defdd70d7e6a04f4f1b71d353653682d594106`. Its source is included as a Git
submodule at `third_party/android-airplay-server`.

The companion remains a separate Android package and process
(`com.sidescreen.airplayreceiver`). This preserves the SideTab client identity
and keeps the receiver's upstream GPL-3.0 code separate. The local patch changes
the package id, app/server name, and lets the build select target ABIs; it is
stored at `third_party/patches/android-airplay-server-sidetab.patch`. The
upstream license and source are in the submodule.

## Build and install

The receiver needs JDK 17–21, Android SDK API 36, NDK `27.0.12077973`, and CMake
as pinned by the upstream Android project. The build script initializes the
recursive upstream submodules and builds its debug APK. The default APK includes
arm64, 32-bit ARM, and x86_64; set `SIDETAB_AIRPLAY_ABIS=arm64-v8a` to build only
for an arm64 tablet.

```bash
./scripts/build_airplay_receiver.sh
```

`./scripts/build_android.sh` builds the SideTab Android client and the AirPlay
receiver. `./scripts/install_android.sh` installs both on the selected Android
device. To target a paired wireless ADB transport rather than a USB device:

```bash
SIDESCREEN_ADB_SERIAL=tablet-ip:port ./scripts/install_android.sh
```

For a previously built pair, add `--skip-build`. Network ADB installs do not
alter the USB `adb reverse` mappings.

## Start a Mac display session

1. Open **SideTab** on Android and tap **Open** in the AirPlay display card.
2. The companion starts its server when its main screen opens by default. Keep
   the companion running while the Mac uses the display.
3. On Mac, open **System Settings → Displays → +**, select **SideTab AirPlay**,
   then choose mirroring or extending for the session.
4. Stop the AirPlay service in its Android app when the display is no longer
   needed.

The service does not start on device reboot by default. The companion currently
does not require an AirPlay PIN by default, so start it only on a trusted Wi-Fi
network and stop it when finished. The upstream receiver offers a PIN setting;
test macOS discovery and connection compatibility before enabling it.

## Acceptance evidence

| Evidence | State |
| --- | --- |
| Source and Android/Mac entry points | Implemented on the local integration branch. |
| Android client tests and lint | Passed locally on 2026-10-05 after the generation-fence changes. |
| Android and Mac builds | Passed locally on 2026-10-05; receiver built for `arm64-v8a`. |
| Installed on hardware | SideTab and companion APKs installed on a Samsung SM-X800 through paired Wi-Fi ADB. Wireless debugging reports enabled (`adb_wifi_enabled=1`). |
| Mac receiver discovery and AirPlay stream | Verified live on 2026-10-05 (SM-X800, M4 Mac): the Displays **+** picker lists `SideTab AirPlay` and the stream plays. |
| Native scaling | macOS first offers 2302x1440 non-HiDPI H.264, which the tablet upscales. Choosing **1400x876 (HiDPI)** for the new display in Displays settings makes macOS stream native 2800x1752. |
| Sustained smoothness | Output jitter of 18-100 ms was observed, from the receiver's input-coupled decoder drain. Not yet fixed in the receiver. |
| Mac audio to another AirPlay device | macOS 26 does not allow it. Starting an AirPlay display deactivates AirPlay audio to a different endpoint such as a HomePod, and the reverse also holds. Receiver flags cannot change this. Use SideTab's own Wi-Fi mode (see [wireless-60fps.md](wireless-60fps.md)) to keep HomePod audio playing. |

ADB pairing, device enumeration, and APK installation prove the wireless debug
transport works. They do not prove AirPlay discovery, video playback, scaling,
or sustained frame delivery.

Both devices need to be reachable on the same Wi-Fi network, and that network
must pass Bonjour/mDNS discovery. The native macOS **Displays → +** picker selects
the AirPlay target; this feature does not add an AirPlay sender or change the
existing SideTab USB and paired-Wi-Fi stream protocols.

The receiver's default `auto` resolution advertises the tablet's physical panel
dimensions and follows device rotation. Its video surface uses the negotiated
video aspect ratio to fit content without stretching. The receiver caps its
advertised frame rate at 60 FPS by default. Use the receiver's debug overlay to
inspect runtime FPS and dropped frames; build-time configuration alone is not a
smoothness claim.

## Source and license

The upstream receiver is licensed under GPL-3.0. Keep its companion APK,
upstream license, exact source revision, and SideTab patch together when
packaging or redistributing it. `scripts/package_current.sh` includes the
receiver APK, upstream license text, patch, and source provenance in its
manifest. For redistribution, package the corresponding complete upstream
source (including its nested submodules) with the SideTab patch alongside the
receiver binary; the validation package script currently records provenance
but does not create that source archive. SideTab's original application code
remains under the repository's root license.
