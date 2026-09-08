#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
source "$SCRIPT_DIR/android_ports.sh"

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
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi

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
adb install -r "$APK_PATH"

echo ""
echo "✅ App installed successfully!"
echo ""
echo "📲 Setting up USB port forwarding..."
adb reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
adb reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
adb reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
adb reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"

echo "✅ Ports $ANDROID_USB_VIDEO_PORT (video) and $ANDROID_USB_CONTROL_PORT (control) forwarded"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready! Open 'Side Screen' on your Android device"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
