#!/bin/bash
set -euo pipefail

# Install exactly one user-facing host bundle. macOS Screen Recording approval
# is tied to the app's signing identity, so launching a second copy (for
# example exp_bin/SideScreenExp.app) can make an existing grant appear lost.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="${HOME:?HOME is not set}"
SOURCE_APP="$ROOT_DIR/SideScreen.app"
INSTALL_ROOT="${SIDESCREEN_INSTALL_ROOT:-$USER_HOME/Applications}"
TARGET_APP="${SIDESCREEN_INSTALL_APP:-$INSTALL_ROOT/SideScreen.app}"
LAUNCH=false

if [ "${1:-}" = "--launch" ]; then
    LAUNCH=true
elif [ "${1:-}" != "" ]; then
    echo "Usage: $0 [--launch]" >&2
    exit 2
fi

if [ ! -d "$SOURCE_APP" ]; then
    echo "Missing current build: $SOURCE_APP" >&2
    echo "Run ./scripts/build_mac.sh first." >&2
    exit 1
fi

mkdir -p "$INSTALL_ROOT"

PREVIOUS_CDHASH=""
if [ -d "$TARGET_APP" ]; then
    PREVIOUS_CDHASH="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"
fi

# Stop only a process whose executable is inside the exact target bundle.
for pid in $(pgrep -f "$TARGET_APP/Contents/MacOS/SideScreen" || true); do
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

TEMP_ROOT="$(mktemp -d -t sidescreen-install)"
cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

ditto --rsrc --extattr --qtn "$SOURCE_APP" "$TEMP_ROOT/SideScreen.app"
"$SCRIPT_DIR/sign_mac_app.sh" "$TEMP_ROOT/SideScreen.app"

if [ -e "$TARGET_APP" ]; then
    BACKUP_APP="$TARGET_APP.previous.$(date +%Y%m%d-%H%M%S)"
    mv "$TARGET_APP" "$BACKUP_APP"
    echo "Previous bundle preserved at: $BACKUP_APP"
fi
mv "$TEMP_ROOT/SideScreen.app" "$TARGET_APP"

codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
echo "Installed current host: $TARGET_APP"
CURRENT_CDHASH="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"
echo "Current CDHash: ${CURRENT_CDHASH:-unknown}"
if [ -n "$PREVIOUS_CDHASH" ] && [ -n "$CURRENT_CDHASH" ] && [ "$PREVIOUS_CDHASH" != "$CURRENT_CDHASH" ]; then
    echo "WARNING: local ad-hoc code identity changed ($PREVIOUS_CDHASH -> $CURRENT_CDHASH)."
    echo "If Screen Recording shows Granted but SideScreen says Required, rebind this exact bundle in System Settings."
fi
echo "Screen Recording must be granted to this exact bundle; do not launch a legacy copy."
codesign -d -r- "$TARGET_APP" 2>&1 | tail -4

if $LAUNCH; then
    open -n "$TARGET_APP"
fi
