#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
AIRPLAY_APK_PATH="$ROOT_DIR/third_party/android-airplay-server/app/build/outputs/apk/debug/app-debug.apk"
source "$SCRIPT_DIR/android_ports.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/resolve_adb.sh"

ADB_BIN="$(sidescreen_resolve_adb 2>/dev/null || true)"
if [ -z "$ADB_BIN" ]; then
    echo "❌ ADB not found"
    echo "   Install Android Studio platform-tools or set SIDESCREEN_ADB"
    exit 1
fi

SKIP_BUILD=0
if [ "${1:-}" = "--skip-build" ]; then
    SKIP_BUILD=1

elif [ "$#" -gt 0 ]; then
    echo "❌ Unknown option: $1"
    echo "   Usage: ./scripts/install_android.sh [--skip-build]"
    exit 2
fi

echo "📱 Installing Android app..."

# Confirm the target before spending time on a build. A normal install always
# rebuilds so an old ignored APK can never masquerade as the current source.
"$ADB_BIN" start-server >/dev/null
ADB_DEVICES="$($ADB_BIN devices -l 2>&1 || true)"
REQUESTED_SERIAL="${SIDESCREEN_ADB_SERIAL:-${ANDROID_SERIAL:-}}"
if [ -n "$REQUESTED_SERIAL" ]; then
    ADB_SERIAL="$(printf '%s\n' "$ADB_DEVICES" | awk -v serial="$REQUESTED_SERIAL" '$1 == serial && $2 == "device" { print $1; exit }')"
    # A remembered Wi-Fi serial goes stale whenever wireless debugging toggles
    # its port. Reconnecting is cheap and idempotent, so a requested network
    # target is retried before being reported as unavailable.
    if [ -z "$ADB_SERIAL" ] && [[ "$REQUESTED_SERIAL" == *:* ]]; then
        "$ADB_BIN" connect "$REQUESTED_SERIAL" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6; do
            ADB_SERIAL="$("$ADB_BIN" devices -l 2>/dev/null | awk -v serial="$REQUESTED_SERIAL" '$1 == serial && $2 == "device" { print $1; exit }')"
            if [ -n "$ADB_SERIAL" ]; then
                break
            fi
            sleep 0.5
        done
    fi
    if [ -z "$ADB_SERIAL" ]; then
        echo "❌ Requested ADB device is not connected and ready: $REQUESTED_SERIAL"
        printf '%s\n' "$ADB_DEVICES" | sed 's/^/   /'
        exit 1
    fi
else
    # USB first, then any already-connected network transport.
    ADB_SERIAL="$(printf '%s\n' "$ADB_DEVICES" | sidescreen_first_ready_serial)"
fi

if [ -z "$ADB_SERIAL" ]; then
    # No transport yet: bring up the paired wireless bridge before giving up.
    echo "🔎 No USB device; looking for a wireless ADB target..."
    ADB_SERIAL="$(sidescreen_connect_wireless_adb "$ADB_BIN" 2>/dev/null || true)"
fi
if [ -z "$ADB_SERIAL" ]; then
    echo "❌ No Android device found via ADB"
    echo "   ADB: $ADB_BIN"
    printf '%s\n' "$ADB_DEVICES" | sed 's/^/   /'
    echo "   USB: unlock the tablet, select a data-capable USB mode, and accept the USB debugging prompt."
    echo "   Wi-Fi: enable Wireless debugging on the same network, pair once, then run"
    echo "          ./scripts/connect_wireless_adb.sh"
    exit 1
fi
echo "  ✓ Android device connected: $ADB_SERIAL"
export SIDESCREEN_ADB_SERIAL="$ADB_SERIAL"

# Preserve the currently installed APK and every existing local APK output
# before the fresh build can replace the ignored build artifact.
echo "🗄️ Backing up existing Android APK artifacts..."
"$ROOT_DIR/scripts/backup_android_apks.sh"

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "🔨 Building a fresh debug APK..."
    "$SCRIPT_DIR/build_android.sh"
elif [ ! -f "$APK_PATH" ]; then
    echo "❌ APK not found while --skip-build was requested"
    echo "   Run ./scripts/install_android.sh without --skip-build"
    exit 1
fi

# Install the SideTab client. The AirPlay receiver route is discontinued and
# only ships when SIDESCREEN_WITH_AIRPLAY=1 explicitly opts in.
"$ADB_BIN" -s "$ADB_SERIAL" install -r "$APK_PATH"
if [ "${SIDESCREEN_WITH_AIRPLAY:-0}" = "1" ]; then
    if [ ! -f "$AIRPLAY_APK_PATH" ]; then
        echo "❌ AirPlay receiver APK not found"
        echo "   Run ./scripts/build_airplay_receiver.sh (or install without SIDESCREEN_WITH_AIRPLAY)"
        exit 1
    fi
    "$ADB_BIN" -s "$ADB_SERIAL" install -r "$AIRPLAY_APK_PATH"
fi

echo ""
echo "✅ App installed successfully!"
echo ""
if [[ "$ADB_SERIAL" == *:* ]]; then
    echo "📶 Network ADB target selected; USB reverse ports are not changed."
else
    echo "📲 Setting up USB port forwarding..."
    "$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
    "$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
    "$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
    "$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"
    echo "✅ Ports $ANDROID_USB_VIDEO_PORT (video) and $ANDROID_USB_CONTROL_PORT (control) forwarded"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready! Open 'SideTab' on your Android device"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
