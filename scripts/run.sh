#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# The path is resolved from this script's directory at runtime.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/android_ports.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/resolve_adb.sh"

ADB_BIN="$(sidescreen_resolve_adb 2>/dev/null || true)"
ADB_SERIAL=""

echo "🚀 Starting Side Screen..."

# Keep the user-facing install directory free of snapshots left by older
# installers. The helper is scoped to SideScreen.app.previous.* only.
"$SCRIPT_DIR/cleanup_old_app_copies.sh" --apply

# Kill any existing instance
pkill -x SideScreen 2>/dev/null || true
sleep 0.3

# Check if app bundle exists
if [ -d "$ROOT_DIR/SideScreen.app" ]; then
    echo "  Opening SideScreen.app..."
    /usr/bin/open -n "$ROOT_DIR/SideScreen.app"
elif [ -f "$ROOT_DIR/MacHost/.build/release/SideScreen" ]; then
    echo "  Running release binary..."
    "$ROOT_DIR/MacHost/.build/release/SideScreen" &
elif [ -f "$ROOT_DIR/MacHost/.build/debug/SideScreen" ]; then
    echo "  Running debug binary..."
    "$ROOT_DIR/MacHost/.build/debug/SideScreen" &
else
    echo "❌ No build found. Building now..."
    "$SCRIPT_DIR/build_mac.sh"
    echo ""
    echo "  Opening SideScreen.app..."
    /usr/bin/open -n "$ROOT_DIR/SideScreen.app"
fi

echo ""
echo "✅ Mac app started!"
echo ""

# Setup USB if device connected
if [ -n "$ADB_BIN" ]; then
    ADB_SERIAL="$("$ADB_BIN" devices | awk '$2 == "device" { print $1; exit }')"
fi
if [ -n "${ADB_SERIAL:-}" ]; then
    echo "📱 Android device detected, setting up USB..."
    "$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
    "$ADB_BIN" -s "$ADB_SERIAL" reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
    "$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
    "$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"
    echo "  ✓ Video/control port forwarding ready"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Open 'Side Screen' on Android and tap Connect"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
