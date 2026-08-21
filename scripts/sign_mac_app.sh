#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/SideScreen.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

# Keep an explicit local-development requirement so every build path reports
# the same bundle identity. This does not make an ad-hoc CDHash stable: macOS
# may still require a Screen Recording rebind after the executable changes. A
# real persistent Apple signing identity is required for approval continuity
# across arbitrary local rebuilds.
LOCAL_REQUIREMENT='=designated => identifier "com.sidescreen.app" and info[CFBundleName] = "Side Screen"'

codesign \
    --force \
    --deep \
    --sign - \
    --requirements "$LOCAL_REQUIREMENT" \
    --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
