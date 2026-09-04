#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/android_ports.sh"

echo "🔧 Setting up USB port forwarding..."

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "❌ No Android device found via ADB"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Connect device via USB cable"
    echo "  2. Enable Developer Options on device"
    echo "  3. Enable USB Debugging in Developer Options"
    echo "  4. Accept the USB debugging prompt on device"
    echo "  5. Run this script again"
    exit 1
fi

echo "  ✓ Device connected"

# Remove existing reverse
echo "  Clearing existing port forwards..."
adb reverse --remove-all 2>/dev/null || true
sleep 0.5

# Setup new reverse
echo "  Setting up ports $ANDROID_USB_VIDEO_PORT (video) and $ANDROID_USB_CONTROL_PORT (control)..."
adb reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
adb reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"

# Verify
if adb reverse --list | grep -q "tcp:$ANDROID_USB_VIDEO_PORT" && \
   adb reverse --list | grep -q "tcp:$ANDROID_USB_CONTROL_PORT"; then
    echo ""
    echo "✅ USB port forwarding active!"
    echo ""
    adb reverse --list
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ready to connect. Make sure Mac app is running."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "❌ Port forwarding failed"
    exit 1
fi
