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

SIGNING_IDENTITY="${SIDESCREEN_CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/^[[:space:]]*[0-9]+\)/ && NF >= 2 { print $2; exit }')
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "  Signing with: $SIGNING_IDENTITY"
    # Let codesign derive its normal certificate-backed designated
    # requirement. This keeps Screen Recording approval attached to the same
    # development identity across local rebuilds and app-bundle paths.
    codesign \
        --force \
        --deep \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" \
        "$APP_PATH"
else
    echo "  No valid development identity found; using stable ad-hoc signing"
    codesign \
        --force \
        --deep \
        --sign - \
        --requirements "$LOCAL_REQUIREMENT" \
        --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" \
        "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
