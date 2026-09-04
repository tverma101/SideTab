#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/android_ports.sh"

echo "🚀 Starting Side Screen..."

# Kill any existing instance
pkill -x SideScreen 2>/dev/null || true
sleep 0.3

# Check if app bundle exists
if [ -d "$ROOT_DIR/SideScreen.app" ]; then
    echo "  Opening SideScreen.app..."
    open "$ROOT_DIR/SideScreen.app"
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
    open "$ROOT_DIR/SideScreen.app"
fi

echo ""
echo "✅ Mac app started!"
echo ""

# Setup USB if device connected
if adb devices 2>/dev/null | grep -q "device$"; then
    echo "📱 Android device detected, setting up USB..."
    adb reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
    adb reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
    adb reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
    adb reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"
    echo "  ✓ Video/control port forwarding ready"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Open 'Side Screen' on Android and tap Connect"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
