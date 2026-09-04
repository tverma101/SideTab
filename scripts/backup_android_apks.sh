#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PACKAGE_NAME="${SIDESCREEN_ANDROID_PACKAGE:-com.sidescreen.app}"
BACKUP_ROOT="${SIDESCREEN_APK_BACKUP_DIR:-$ROOT_DIR/backups/apk}"
APK_OUTPUT_ROOT="$ROOT_DIR/AndroidClient/app/build/outputs/apk"
ADB_BIN="${ADB:-adb}"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK_ROOT" && -d "$HOME/Library/Android/sdk" ]]; then
    SDK_ROOT="$HOME/Library/Android/sdk"
fi

if command -v aapt >/dev/null 2>&1; then
    AAPT_BIN="$(command -v aapt)"
else
    AAPT_BIN="${SDK_ROOT:+$SDK_ROOT/build-tools/35.0.0/aapt}"
fi

if command -v apksigner >/dev/null 2>&1; then
    APKSIGNER_BIN="$(command -v apksigner)"
else
    APKSIGNER_BIN="${SDK_ROOT:+$SDK_ROOT/build-tools/35.0.0/apksigner}"
fi

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
snapshot_dir="$BACKUP_ROOT/$timestamp"
suffix=1
while [[ -e "$snapshot_dir" ]]; do
    snapshot_dir="$BACKUP_ROOT/${timestamp}-${suffix}"
    suffix=$((suffix + 1))
done
mkdir -p "$snapshot_dir"
manifest_path="$snapshot_dir/MANIFEST.txt"

source_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
source_branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
source_dirty_count="$(git -C "$ROOT_DIR" status --porcelain=v1 2>/dev/null | wc -l | tr -d ' ')"

printf '%s\n' \
    'SideScreen Android APK backup' \
    "created_utc=$timestamp" \
    "package=$PACKAGE_NAME" \
    "source_git_sha=${source_sha:-unknown}" \
    "source_branch=${source_branch:-unknown}" \
    "source_dirty_entries=$source_dirty_count" \
    > "$manifest_path"

artifact_count=0

apk_metadata() {
    local artifact_name="$1"
    local state="$2"
    local apk_path="$3"
    local sha256 size_bytes package_line cert_digest verified_v2

    sha256="$(shasum -a 256 "$apk_path" | awk '{print $1}')"
    if size_bytes="$(stat -f '%z' "$apk_path" 2>/dev/null)"; then
        :
    else
        size_bytes="$(stat -c '%s' "$apk_path")"
    fi

    package_line='unavailable'
    if [[ -n "$AAPT_BIN" && -x "$AAPT_BIN" ]]; then
        package_line="$("$AAPT_BIN" dump badging "$apk_path" 2>/dev/null \
            | sed -n "s/^package: name='\([^']*\)' versionCode='\([^']*\)' versionName='\([^']*\)'.*$/name=\1 versionCode=\2 versionName=\3/p" \
            | head -n 1)"
        package_line="${package_line:-unavailable}"
    fi

    cert_digest='unavailable'
    verified_v2='unavailable'
    if [[ -n "$APKSIGNER_BIN" && -x "$APKSIGNER_BIN" ]]; then
        local signer_output
        signer_output="$("$APKSIGNER_BIN" verify --verbose --print-certs "$apk_path" 2>/dev/null || true)"
        cert_digest="$(printf '%s\n' "$signer_output" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1)"
        verified_v2="$(printf '%s\n' "$signer_output" | sed -n 's/^Verified using v2 scheme (APK Signature Scheme v2): //p' | head -n 1)"
        cert_digest="${cert_digest:-unavailable}"
        verified_v2="${verified_v2:-unavailable}"
    fi

    printf '\n[artifact]\nname=%s\nstate=%s\npath=%s\nsize_bytes=%s\nsha256=%s\npackage=%s\nsigner_sha256=%s\nverified_v2=%s\n' \
        "$artifact_name" "$state" "$apk_path" "$size_bytes" "$sha256" "$package_line" "$cert_digest" "$verified_v2" \
        >> "$manifest_path"
    artifact_count=$((artifact_count + 1))
}

if [[ -d "$APK_OUTPUT_ROOT" ]]; then
    while IFS= read -r -d '' apk_path; do
        relative_path="${apk_path#"$APK_OUTPUT_ROOT"/}"
        safe_name="${relative_path//\//__}"
        destination="$snapshot_dir/source-${safe_name}"
        cp -p "$apk_path" "$destination"
        apk_metadata "source-${safe_name}" "local-build-output" "$destination"
    done < <(find "$APK_OUTPUT_ROOT" -type f -name '*.apk' \
        ! -path '*/androidTest/*' ! -path '*/test/*' -print0)
fi

adb_device=''
adb_serial="${SIDESCREEN_ADB_SERIAL:-${ANDROID_SERIAL:-}}"
if command -v "$ADB_BIN" >/dev/null 2>&1; then
    if [[ -z "$adb_serial" ]]; then
        ready_devices="$("$ADB_BIN" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" {print $1}')"
        ready_count="$(printf '%s\n' "$ready_devices" | sed '/^$/d' | wc -l | tr -d ' ')"
        if [[ "$ready_count" -gt 1 ]]; then
            echo "warning: multiple ADB devices found; backing up the first. Set SIDESCREEN_ADB_SERIAL to choose one." >&2
        fi
        adb_serial="$(printf '%s\n' "$ready_devices" | sed '/^$/d' | head -n 1)"
    fi

    if [[ -n "$adb_serial" ]]; then
        adb_device=("$ADB_BIN" -s "$adb_serial")
        installed_path="$("${adb_device[@]}" shell pm path "$PACKAGE_NAME" 2>/dev/null \
            | sed -n 's/^package://p' | tr -d '\r' | head -n 1)"
        if [[ -n "$installed_path" ]]; then
            installed_destination="$snapshot_dir/installed-base.apk"
            "${adb_device[@]}" pull "$installed_path" "$installed_destination" >/dev/null
            apk_metadata 'installed-base.apk' 'installed-device' "$installed_destination"

            device_model="$("${adb_device[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r' | head -n 1)"
            device_android="$("${adb_device[@]}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' | head -n 1)"
            device_sdk="$("${adb_device[@]}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' | head -n 1)"
            package_state="$("${adb_device[@]}" shell dumpsys package "$PACKAGE_NAME" 2>/dev/null | tr -d '\r' \
                | rg -m 6 'versionCode=|versionName=|firstInstallTime=|lastUpdateTime=' || true)"
            printf '\n[installed_device]\nserial=%s\nmodel=%s\nandroid_release=%s\napi=%s\npackage_path=%s\n%s\n' \
                "$adb_serial" "${device_model:-unknown}" "${device_android:-unknown}" "${device_sdk:-unknown}" "$installed_path" "$package_state" \
                >> "$manifest_path"
        else
            echo "warning: package $PACKAGE_NAME is not installed on ADB device $adb_serial; no device APK copied" >&2
        fi
    else
        echo "warning: no ready ADB device found; local APK outputs were still backed up" >&2
    fi
else
    echo "warning: adb is unavailable; local APK outputs were still backed up" >&2
fi

if [[ "$artifact_count" -eq 0 ]]; then
    rm -f "$manifest_path"
    rmdir "$snapshot_dir" 2>/dev/null || true
    echo "error: no APK artifacts were found to back up" >&2
    exit 1
fi

printf '\nbackup_directory=%s\nartifact_count=%s\n' "$snapshot_dir" "$artifact_count" >> "$manifest_path"
echo "Backed up $artifact_count APK artifact(s) to $snapshot_dir"
echo "Manifest: $manifest_path"
