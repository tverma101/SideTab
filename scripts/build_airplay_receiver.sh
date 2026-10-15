#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RECEIVER_DIR="$ROOT_DIR/third_party/android-airplay-server"
# Applied in order: package identity, then the wireless display fixes.
PATCH_FILES=(
    "$ROOT_DIR/third_party/patches/android-airplay-server-sidetab.patch"
    "$ROOT_DIR/third_party/patches/android-airplay-server-wireless-display.patch"
)
EXPECTED_COMMIT="c8defdd70d7e6a04f4f1b71d353653682d594106"
UXPLAY_DIR="$RECEIVER_DIR/app/src/main/cpp/third_party/UxPlay"
UXPLAY_PATCH_DIR="$RECEIVER_DIR/app/src/main/cpp/patches/UxPlay"
BUILD_LOCK="$RECEIVER_DIR/.sidetab-build.lock"
BUILD_LOG=""
APPLIED_PATCHES=()
UXPLAY_TOUCHED_FILES=()
UXPLAY_TOUCHED_COUNT=0

git -C "$ROOT_DIR" submodule update --init --recursive -- third_party/android-airplay-server
ACTUAL_COMMIT="$(git -C "$RECEIVER_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]]; then
    echo "AirPlay receiver source is not the reviewed v0.0.31 commit." >&2
    echo "  expected=$EXPECTED_COMMIT" >&2
    echo "  actual=$ACTUAL_COMMIT" >&2
    exit 1
fi

if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "Another SideTab AirPlay build is using the pinned receiver checkout." >&2
    exit 1
fi

cleanup_patched_source() {
    # Reverse in the opposite order; reversing also removes files a patch added.
    local i
    for ((i = ${#APPLIED_PATCHES[@]} - 1; i >= 0; i--)); do
        git -C "$RECEIVER_DIR" apply -R "${APPLIED_PATCHES[$i]}" || true
    done
    if [[ "$UXPLAY_TOUCHED_COUNT" -gt 0 && "${UXPLAY_RESET_SAFE:-0}" -eq 1 ]]; then
        git -C "$UXPLAY_DIR" checkout -- "${UXPLAY_TOUCHED_FILES[@]}" || true
    fi
    if [[ -n "$BUILD_LOG" ]]; then rm -f "$BUILD_LOG"; fi
    rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap cleanup_patched_source EXIT

for patch_file in "${PATCH_FILES[@]}"; do
    if git -C "$RECEIVER_DIR" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
        continue # Already applied in this checkout.
    fi
    if ! git -C "$RECEIVER_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
        echo "The pinned AirPlay source no longer accepts $(basename "$patch_file")." >&2
        exit 1
    fi
    patch_targets=()
    while IFS= read -r touched_path; do
        [[ -n "$touched_path" ]] && patch_targets+=("$touched_path")
    done < <(git -C "$RECEIVER_DIR" apply --numstat "$patch_file" | awk -F '\t' 'NF >= 3 { print $3 }')
    if ! git -C "$RECEIVER_DIR" diff HEAD --quiet -- "${patch_targets[@]}"; then
        echo "AirPlay source has local edits in files touched by $(basename "$patch_file")." >&2
        exit 1
    fi
    git -C "$RECEIVER_DIR" apply "$patch_file"
    APPLIED_PATCHES+=("$patch_file")
done

# After the SideTab patches: they add UxPlay patches the upstream build applies too.
for uxplay_patch in "$UXPLAY_PATCH_DIR"/*.patch; do
    while IFS= read -r touched_path; do
        [[ -n "$touched_path" ]] || continue
        already_listed=0
        if [[ " ${UXPLAY_TOUCHED_FILES[*]-} " == *" $touched_path "* ]]; then
            already_listed=1
        fi
        if [[ "$already_listed" -eq 0 ]]; then
            UXPLAY_TOUCHED_FILES+=("$touched_path")
            UXPLAY_TOUCHED_COUNT=$((UXPLAY_TOUCHED_COUNT + 1))
        fi
    done < <(git -C "$UXPLAY_DIR" apply --numstat "$uxplay_patch" | awk -F '\t' 'NF >= 3 { print $3 }')
done
if ! git -C "$UXPLAY_DIR" diff HEAD --quiet -- "${UXPLAY_TOUCHED_FILES[@]}"; then
    echo "AirPlay UxPlay source has local edits in files its upstream build patches." >&2
    exit 1
fi
UXPLAY_RESET_SAFE=1

compatible_java_home() {
    [[ -x "$1/bin/java" ]] || return 1
    local major
    major="$("$1/bin/java" -version 2>&1 | awk -F '"' '/version/ {split($2, v, "."); print v[1]; exit}')"
    case "$major" in 17|18|19|20|21) return 0 ;; *) return 1 ;; esac
}

if [[ -n "${JAVA_HOME:-}" ]]; then
    if ! compatible_java_home "$JAVA_HOME"; then
        echo "JAVA_HOME must point to a JDK 17–21 supported by this Gradle wrapper." >&2
        exit 1
    fi
else
    studio_java_home="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if compatible_java_home "$studio_java_home"; then
        export JAVA_HOME="$studio_java_home"
    elif [[ -x "/usr/libexec/java_home" ]]; then
        for java_version in 21 17; do
            detected_java_home="$(/usr/libexec/java_home -v "$java_version" 2>/dev/null || true)"
            if compatible_java_home "$detected_java_home"; then
                export JAVA_HOME="$detected_java_home"
                break
            fi
        done
    fi
fi

if [[ -z "${JAVA_HOME:-}" ]] || [[ ! -x "$JAVA_HOME/bin/java" ]]; then
    echo "Compatible JDK not found. Set JAVA_HOME to JDK 17 or 21." >&2
    exit 1
fi

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" && -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
fi

AIRPLAY_ABIS="${SIDETAB_AIRPLAY_ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
echo "Building pinned SideTab AirPlay companion (ABIs: $AIRPLAY_ABIS)..."
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/sidetab-airplay-build.XXXXXX")"
(
    cd "$RECEIVER_DIR"
    ./gradlew --no-daemon --stacktrace --console=plain \
        -PsidetabReceiverAbis="$AIRPLAY_ABIS" \
        assembleDebug
) >"$BUILD_LOG" 2>&1 || {
    tail -n 120 "$BUILD_LOG" >&2
    exit 1
}
rg -m 1 '^BUILD SUCCESSFUL' "$BUILD_LOG" || true

APK_PATH="$RECEIVER_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "$APK_PATH" ]]; then
    echo "AirPlay receiver build finished without producing $APK_PATH" >&2
    exit 1
fi
echo "AirPlay receiver APK: $APK_PATH"
