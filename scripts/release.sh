#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')

echo "======================================="
echo "  Side Screen - Release v$VERSION"
echo "======================================="
echo ""

# 1. Lint
echo "[1/3] Linting..."
cd "$ROOT_DIR/MacHost"
if command -v swiftlint &>/dev/null; then
    swiftlint lint --config .swiftlint.yml --strict --quiet
    echo "  Swift lint OK"
fi

cd "$ROOT_DIR/AndroidClient"
if command -v ktlint &>/dev/null; then
    ktlint "app/src/main/java/**/*.kt" --relative
    echo "  Kotlin lint OK"
fi

# 2. Build and verify local release artifacts
echo "[2/3] Building release artifacts..."
cd "$ROOT_DIR/AndroidClient"
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then
    export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
fi
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
./gradlew assembleRelease
APK="$ROOT_DIR/AndroidClient/app/build/outputs/apk/release/app-release.apk"
if [ ! -f "$APK" ]; then
    echo "❌ Release APK was not produced"
    exit 1
fi
shasum -a 256 "$APK"

# 3. Release handoff (publishing is intentionally manual)
echo "[3/3] Release handoff"
echo "  Build and checksum complete. Create/publish the tag and release only after review."

echo ""
echo "======================================="
echo "  APK: $ROOT_DIR/AndroidClient/app/build/outputs/apk/release/app-release.apk"
echo "  Done! Verify and publish the APK manually; no hosted workflow is configured."
echo "======================================="
