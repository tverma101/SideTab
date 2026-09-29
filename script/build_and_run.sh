#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SideScreen"
BUNDLE_ID="com.sidescreen.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
    echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
    run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

# build_mac.sh is the single build path. It also cleans stale installed
# snapshots after a successful signed bundle is produced.
"$ROOT_DIR/scripts/build_mac.sh"

if [ ! -x "$APP_BINARY" ]; then
    echo "Built app executable not found: $APP_BINARY" >&2
    exit 1
fi

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        exec lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\" OR subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        echo "Verified running app: $APP_BUNDLE"
        ;;
esac
