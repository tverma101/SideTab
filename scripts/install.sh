#!/bin/bash
set -e

# Navigate to project root (parent of scripts directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/android_ports.sh"
cd "$ROOT_DIR"

echo "🚀 Installing Side Screen..."
echo ""

# Prefer an explicitly configured JDK, then Android Studio or the macOS Java locator.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    if [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
        export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    elif [ -x "/usr/libexec/java_home" ]; then
        detected_java_home=$(/usr/libexec/java_home 2>/dev/null || true)
        if [ -x "$detected_java_home/bin/java" ]; then
            export JAVA_HOME="$detected_java_home"
        fi
    fi
fi

if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then
    export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
fi

# Check Java
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "❌ Java 11+ not found. Set JAVA_HOME or install Android Studio."
    exit 1
fi

# Check ADB connection first
echo "📱 Checking ADB connection..."
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi
echo "  ✓ Android device connected"
echo ""

# Build macOS app
echo "📦 Building macOS app..."
"$SCRIPT_DIR/build_mac.sh"
echo "  ✓ universal macOS app built and signed"
echo ""

# Build Android app
echo "📦 Building Android app..."
cd AndroidClient
./gradlew assembleDebug
cd "$ROOT_DIR"
echo "  ✓ Android app built"
echo ""

# Install Android app
echo "📱 Installing Android app..."
"$SCRIPT_DIR/backup_android_apks.sh"
adb install -r AndroidClient/app/build/outputs/apk/debug/app-debug.apk
echo "  ✓ Android app installed"
echo ""

# Setup ADB reverse (with retry)
echo "🔧 Setting up USB port forwarding..."
adb reverse --remove tcp:"$ANDROID_USB_VIDEO_PORT" 2>/dev/null || true
adb reverse --remove tcp:"$ANDROID_USB_CONTROL_PORT" 2>/dev/null || true
sleep 0.5
adb reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
adb reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"

# Verify ADB reverse is active
echo "🔍 Verifying port forwarding..."
if adb reverse --list | grep -q "tcp:$ANDROID_USB_VIDEO_PORT" && \
   adb reverse --list | grep -q "tcp:$ANDROID_USB_CONTROL_PORT"; then
    echo "  ✓ Ports $ANDROID_USB_VIDEO_PORT and $ANDROID_USB_CONTROL_PORT forwarded successfully"
else
    echo "  ⚠️  Port forwarding setup but verification failed"
    echo "  Run './scripts/setup-usb.sh' if connection issues occur"
fi
echo ""

echo "✅ Installation complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To start streaming:"
echo "  1. Start Mac app: open SideScreen.app"
echo "     (or run: MacHost/.build/release/SideScreen)"
echo "  2. Open 'Side Screen' app on Android"
echo "  3. Tap Connect"
echo ""
echo "💡 Troubleshooting:"
echo "  • Connection fails: ./scripts/setup-usb.sh"
echo "  • Check server: lsof -i :$ANDROID_USB_VIDEO_PORT"
echo "  • Check forwarding: adb reverse --list (ports $ANDROID_USB_VIDEO_PORT/$ANDROID_USB_CONTROL_PORT)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
