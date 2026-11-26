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

# Return the first ready physical USB transport from `adb devices -l` input.
# Wi-Fi transports are also reported as `device`, so `$2 == device` alone is
# unsafe when Android wireless debugging is enabled at the same time.
sidescreen_first_usb_serial() {
    awk '
        NR > 1 && $2 == "device" {
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^usb:/) {
                    print $1
                    exit
                }
            }
        }
    '
}

# Resolve a physical USB device directly when a caller does not already have
# the `adb devices -l` output available for diagnostics.
sidescreen_resolve_usb_serial() {
    local adb_bin="${1:-}"
    [[ -n "$adb_bin" ]] || return 1
    "$adb_bin" devices -l 2>/dev/null | sidescreen_first_usb_serial
}

# Return the first ready network transport (`host:port`) from `adb devices`
# input. A wireless-debugging or `adb tcpip` transport is reported as `device`
# with a host:port serial instead of a `usb:` field.
sidescreen_first_network_serial() {
    awk '
        NR > 1 && $2 == "device" && $1 ~ /:[0-9]+$/ {
            print $1
            exit
        }
    '
}

# Prefer a physical USB transport, then fall back to a connected network one.
# This is what the install/backup scripts want: a username-less tablet that is
# only reachable over Wi-Fi still counts as a target.
sidescreen_first_ready_serial() {
    local usb
    usb="$(sidescreen_first_usb_serial)"
    if [[ -n "$usb" ]]; then
        printf '%s\n' "$usb"
        return 0
    fi
    sidescreen_first_network_serial
}

# Resolve the first ready transport directly, USB first.
sidescreen_resolve_ready_serial() {
    local adb_bin="${1:-}"
    [[ -n "$adb_bin" ]] || return 1
    "$adb_bin" devices -l 2>/dev/null | sidescreen_first_ready_serial
}

# Discover a paired wireless-debugging / network ADB target and connect to it.
#
# Prints the ready serial on success. The tablet must already be paired with
# this Mac once (`adb pair host:port`) or listening on a plain `adb tcpip`
# port, because pairing is interactive and cannot run unattended here.
#
# Sources of candidates, in order:
#   1. `SIDESCREEN_WIRELESS_ADB` / `SIDESCREEN_ADB_SERIAL` (host:port)
#   2. mDNS `_adb-tls-connect._tcp` services advertised by Android wireless
#      debugging, which is the reliable way to find the rotating port.
#   3. A plain `adb tcpip` transport on the conventional port 5555 against a
#      host named by `SIDESCREEN_WIRELESS_HOST`.
sidescreen_connect_wireless_adb() {
    local adb_bin="${1:-}"
    [[ -n "$adb_bin" ]] || return 1

    local existing
    existing="$("$adb_bin" devices 2>/dev/null | sidescreen_first_network_serial)"
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    local -a candidates=()
    local explicit="${SIDESCREEN_WIRELESS_ADB:-${SIDESCREEN_ADB_SERIAL:-}}"
    if [[ -n "$explicit" && "$explicit" == *:* ]]; then
        candidates+=("$explicit")
    fi

    local mdns_serial
    while IFS= read -r mdns_serial; do
        [[ -n "$mdns_serial" ]] && candidates+=("$mdns_serial")
    done < <(
        "$adb_bin" mdns services 2>/dev/null \
            | awk '/_adb-tls-connect\._tcp/ { print $NF }'
    )

    local wireless_host="${SIDESCREEN_WIRELESS_HOST:-}"
    if [[ -n "$wireless_host" ]]; then
        candidates+=("${wireless_host%:*}:5555")
    fi

    local candidate
    for candidate in ${candidates[@]+"${candidates[@]}"}; do
        "$adb_bin" connect "$candidate" >/dev/null 2>&1 || true
        # `adb connect` returns before the transport is ready; poll briefly so
        # the caller never sees a half-established target.
        local _attempt
        for _attempt in 1 2 3 4 5 6 7 8 9 10; do
            if "$adb_bin" devices 2>/dev/null \
                | awk -v serial="$candidate" '$1 == serial && $2 == "device" { found = 1 } END { exit !found }'; then
                printf '%s\n' "$candidate"
                return 0
            fi
            sleep 0.3
        done
    done

    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sidescreen_resolve_adb
fi
