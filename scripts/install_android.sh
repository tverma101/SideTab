#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
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
ADB_SERIAL="$(printf '%s\n' "$ADB_DEVICES" | awk '$2 == "device" { print $1; exit }')"
if [ -z "$ADB_SERIAL" ]; then
    echo "❌ No Android device found via ADB"
    echo "   ADB: $ADB_BIN"
    printf '%s\n' "$ADB_DEVICES" | sed 's/^/   /'
    echo "   Unlock the tablet, select a data-capable USB mode, and accept the USB debugging prompt."
    exit 1
fi
echo "  ✓ Android device connected: $ADB_SERIAL"

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

# Install APK
"$ADB_BIN" -s "$ADB_SERIAL" install -r "$APK_PATH"

echo ""
echo "✅ App installed successfully!"
echo ""
echo "📲 Setting up USB port forwarding..."
"$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
"$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
"$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
"$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"

echo "✅ Ports $ANDROID_USB_VIDEO_PORT (video) and $ANDROID_USB_CONTROL_PORT (control) forwarded"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready! Open 'Side Screen' on your Android device"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
