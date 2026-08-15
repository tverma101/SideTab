#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/SideScreen.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

# Ad-hoc signatures normally use a changing CDHash as their designated
# requirement. TCC then sees every local rebuild as a different application and
# forgets Screen Recording approval. Embed an explicit, stable local-development
# requirement so all SideScreen build paths retain the same TCC identity.
LOCAL_REQUIREMENT='=designated => identifier "com.sidescreen.app" and info[CFBundleName] = "Side Screen"'

codesign \
    --force \
    --deep \
    --sign - \
    --requirements "$LOCAL_REQUIREMENT" \
    --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
