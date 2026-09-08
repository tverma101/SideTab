#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/android_ports.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/resolve_adb.sh"

ADB_BIN="$(sidescreen_resolve_adb 2>/dev/null || true)"
if [ -z "$ADB_BIN" ]; then
    echo "❌ ADB not found"
    echo "   Install Android Studio platform-tools or set SIDESCREEN_ADB"
    exit 1
fi

echo "🔧 Setting up USB port forwarding..."

# Check ADB connection
"$ADB_BIN" start-server >/dev/null
ADB_DEVICES="$($ADB_BIN devices -l 2>&1 || true)"
ADB_SERIAL="$(printf '%s\n' "$ADB_DEVICES" | awk '$2 == "device" { print $1; exit }')"
if [ -z "$ADB_SERIAL" ]; then
    echo "❌ No Android device found via ADB"
    echo "   ADB: $ADB_BIN"
    printf '%s\n' "$ADB_DEVICES" | sed 's/^/   /'
    echo ""
    echo "Troubleshooting:"
    echo "  1. Connect device via USB cable"
    echo "  2. Enable Developer Options on device"
    echo "  3. Enable USB Debugging in Developer Options"
    echo "  4. Accept the USB debugging prompt on device"
    echo "  5. Run this script again"
    exit 1
fi

echo "  ✓ Device connected: $ADB_SERIAL"

# Remove existing reverse
echo "  Clearing existing port forwards..."
"$ADB_BIN" -s "$ADB_SERIAL" reverse --remove-all 2>/dev/null || true
sleep 0.5

# Setup new reverse
echo "  Setting up ports $ANDROID_USB_VIDEO_PORT (video) and $ANDROID_USB_CONTROL_PORT (control)..."
"$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_VIDEO_PORT" tcp:"$ANDROID_USB_VIDEO_PORT"
"$ADB_BIN" -s "$ADB_SERIAL" reverse tcp:"$ANDROID_USB_CONTROL_PORT" tcp:"$ANDROID_USB_CONTROL_PORT"

# Verify
if "$ADB_BIN" -s "$ADB_SERIAL" reverse --list | grep -q "tcp:$ANDROID_USB_VIDEO_PORT" && \
   "$ADB_BIN" -s "$ADB_SERIAL" reverse --list | grep -q "tcp:$ANDROID_USB_CONTROL_PORT"; then
    echo ""
    echo "✅ USB port forwarding active!"
    echo ""
    "$ADB_BIN" -s "$ADB_SERIAL" reverse --list
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ready to connect. Make sure Mac app is running."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "❌ Port forwarding failed"
    exit 1
fi
