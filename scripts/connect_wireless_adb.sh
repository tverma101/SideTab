#!/usr/bin/env bash
set -euo pipefail

# SideTab wireless ADB bridge.
#
# `install_android.sh` and friends can target a Wi-Fi transport, but a
# wireless-debugging tablet rotates its port on every toggle, so the address
# cannot be hard-coded. This script finds and connects the already-paired
# target and prints the serial those helpers accept:
#
#   SERIAL="$(./scripts/connect_wireless_adb.sh --print-serial)"
#   SIDESCREEN_ADB_SERIAL="$SERIAL" ./scripts/install_android.sh
#
# Sources, in order: an explicit SIDESCREEN_WIRELESS_ADB/SIDESCREEN_ADB_SERIAL,
# mDNS `_adb-tls-connect._tcp` services advertised by Android wireless
# debugging, then a plain `adb tcpip` transport on SIDESCREEN_WIRELESS_HOST
# (port 5555). Pairing stays interactive: run `adb pair host:port` once first if
# the tablet and this Mac have never been paired.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/resolve_adb.sh"

PRINT_SERIAL=0
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --print-serial) PRINT_SERIAL=1 ;;
        --disconnect) ACTION="disconnect" ;;
        --status) ACTION="status" ;;
        -h|--help)
            cat <<'EOF'
Usage: ./scripts/connect_wireless_adb.sh [--print-serial] [--status] [--disconnect]

Ensures a wireless ADB transport to the paired tablet and prints its serial.

  --print-serial   Print only the ready serial (for command substitution).
  --status         Report the current ADB transports and exits.
  --disconnect     Drop the wireless transport(s).

Environment:
  SIDESCREEN_WIRELESS_ADB   Explicit host:port to connect.
  SIDESCREEN_WIRELESS_HOST  Host for a plain `adb tcpip` transport (port 5555).
  SIDESCREEN_ADB            ADB binary override.
EOF
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

ADB_BIN="$(sidescreen_resolve_adb 2>/dev/null || true)"
if [[ -z "$ADB_BIN" ]]; then
    echo "❌ ADB not found" >&2
    echo "   Install Android Studio platform-tools or set SIDESCREEN_ADB" >&2
    exit 1
fi

"$ADB_BIN" start-server >/dev/null 2>&1 || true

if [[ "$ACTION" == "status" ]]; then
    echo "ADB: $ADB_BIN"
    "$ADB_BIN" devices -l
    exit 0
fi

if [[ "$ACTION" == "disconnect" ]]; then
    disconnected=0
    while IFS= read -r serial; do
        [[ -n "$serial" ]] || continue
        "$ADB_BIN" disconnect "$serial" >/dev/null 2>&1 || true
        echo "  ✂️  Disconnected $serial"
        disconnected=1
    done < <("$ADB_BIN" devices 2>/dev/null | sidescreen_first_network_serial)
    if [[ "$disconnected" -eq 0 ]]; then
        echo "  No wireless ADB transport was connected."
    fi
    exit 0
fi

SERIAL="$(sidescreen_connect_wireless_adb "$ADB_BIN" || true)"
if [[ -z "$SERIAL" ]]; then
    if [[ "$PRINT_SERIAL" -eq 1 ]]; then
        exit 1
    fi
    echo "❌ No wireless ADB transport found" >&2
    echo "   ADB: $ADB_BIN" >&2
    "$ADB_BIN" devices -l 2>&1 | sed 's/^/   /' >&2
    cat >&2 <<'EOF'

To set it up:
  1. Tablet: Developer options → Wireless debugging ON (same Wi-Fi as this Mac).
  2. Tablet: Wireless debugging → Pair device with pairing code.
  3. Mac:    adb pair <host>:<pair-port>   (enter the code shown on the tablet)
  4. Re-run this script.

If the port is not advertised over mDNS, pass it directly:
  SIDESCREEN_WIRELESS_ADB=<host>:<port> ./scripts/connect_wireless_adb.sh
EOF
    exit 1
fi

MODEL="$("$ADB_BIN" -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"

if [[ "$PRINT_SERIAL" -eq 1 ]]; then
    printf '%s\n' "$SERIAL"
    exit 0
fi

echo "📶 Wireless ADB bridge ready"
echo "  ✓ Device connected: $SERIAL${MODEL:+ ($MODEL)}"
echo ""
echo "Push an APK over Wi-Fi with:"
echo "  SIDESCREEN_ADB_SERIAL=$SERIAL ./scripts/install_android.sh"
