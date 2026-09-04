#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Building Android Client..."
cd "$ROOT_DIR/AndroidClient"

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

# Check if Java is available
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "❌ Java 11+ not found. Set JAVA_HOME or install Android Studio."
    exit 1
fi

./gradlew assembleDebug

echo ""
echo "✅ Build successful!"
echo ""
echo "📦 APK: $ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "To install on device:"
echo "  ./scripts/install_android.sh  # snapshots old APKs before install"
echo "  (the installer archives the previous device APK first)"
