#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Building Android Client..."
cd "$ROOT_DIR/AndroidClient"

# AGP requires JDK 17+, while this Gradle wrapper supports running on 17–21.
# A newer system Java must not silently become the build runtime.
compatible_java_home() {
    [ -x "$1/bin/java" ] || return 1
    local major
    major=$("$1/bin/java" -version 2>&1 | awk -F '"' '/version/ {split($2, v, "."); print v[1]; exit}')
    case "$major" in 17|18|19|20|21) return 0 ;; *) return 1 ;; esac
}

if [ -n "${JAVA_HOME:-}" ]; then
    if ! compatible_java_home "$JAVA_HOME"; then
        echo "❌ JAVA_HOME must point to a JDK 17–21 supported by this Gradle wrapper." >&2
        exit 1
    fi
else
    studio_java_home="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if compatible_java_home "$studio_java_home"; then
        export JAVA_HOME="$studio_java_home"
    elif [ -x "/usr/libexec/java_home" ]; then
        for java_version in 21 17; do
            detected_java_home=$(/usr/libexec/java_home -v "$java_version" 2>/dev/null || true)
            if compatible_java_home "$detected_java_home"; then
                export JAVA_HOME="$detected_java_home"
                break
            fi
        done
    fi
fi

if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then
    export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
fi

# Check if Java is available
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "❌ Compatible JDK not found. Set JAVA_HOME to JDK 17 or 21."
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
