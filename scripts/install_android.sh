#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
source "$SCRIPT_DIR/android_ports.sh"

echo "📱 Installing Android app..."

# Check if APK exists
if [ ! -f "$APK_PATH" ]; then
    echo "❌ APK not found. Building first..."
    "$SCRIPT_DIR/build_android.sh"
fi

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi

# Preserve the installed APK and all current local outputs before replacing
# anything. The helper uses a unique timestamped directory and never
# overwrites an earlier snapshot.
echo "🗄️ Backing up existing Android APK artifacts..."
"$ROOT_DIR/scripts/backup_android_apks.sh"

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
