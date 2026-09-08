#!/usr/bin/env bash

# Resolve one ADB executable for every SideScreen helper script.
#
# Android Studio's platform-tools are preferred because they track newer
# Android releases and keep the install/reverse path on the same binary. An
# explicit SIDESCREEN_ADB (or legacy ADB) override remains available for CI
# and unusual SDK layouts.

sidescreen_resolve_adb() {
    local explicit="${SIDESCREEN_ADB:-${ADB:-}}"
    local candidate sdk_root

    if [[ -n "$explicit" ]]; then
        if [[ "$explicit" == */* ]]; then
            [[ -x "$explicit" ]] || return 1
            printf '%s\n' "$explicit"
            return 0
        fi
        command -v "$explicit"
        return $?
    fi

    local sdk_roots=()
    [[ -n "${ANDROID_HOME:-}" ]] && sdk_roots+=("$ANDROID_HOME")
    [[ -n "${ANDROID_SDK_ROOT:-}" && "${ANDROID_SDK_ROOT:-}" != "${ANDROID_HOME:-}" ]] && sdk_roots+=("$ANDROID_SDK_ROOT")
    [[ -d "$HOME/Library/Android/sdk" ]] && sdk_roots+=("$HOME/Library/Android/sdk")

    for sdk_root in "${sdk_roots[@]}"; do
        candidate="$sdk_root/platform-tools/adb"
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    for candidate in /opt/homebrew/bin/adb /usr/local/bin/adb; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    command -v adb
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sidescreen_resolve_adb
fi
