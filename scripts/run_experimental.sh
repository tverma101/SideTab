#!/bin/bash
# Build and install an EXPERIMENTAL SideTab build that is fully independent of
# the live app.
#
# Why this exists: the live install at ~/Applications/SideScreen.app is the one
# the user actually runs. It must never be replaced by a work-in-progress build.
# A plain copy is not enough to keep them separate, because:
#
#   - the signing script pins a designated requirement of
#     `identifier "com.sidescreen.app" and info[CFBundleName] = "Side Screen"`,
#     so a copy shares a TCC identity and would inherit (and clobber) the live
#     app's Screen Recording grant;
#   - both would have the same UserDefaults domain, so experimental settings
#     would overwrite the live app's settings;
#   - LaunchServices cannot cleanly host two bundles with one identifier.
#
# This script therefore renames the bundle, gives it a distinct identifier,
# re-signs with a matching designated requirement, and installs to a separate
# root. The live app is never read, written, or signed by this script.
#
# Usage:
#   scripts/run_experimental.sh              # build + install + launch
#   scripts/run_experimental.sh --no-build   # re-install the existing build
#   scripts/run_experimental.sh --no-launch  # install only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The live install. Nothing in this script may write here.
LIVE_APP="$HOME/Applications/SideScreen.app"

# The experimental app's own identity.
EXP_NAME="${SIDESCREEN_EXP_NAME:-SideTab Exp}"
EXP_SLUG="${SIDESCREEN_EXP_SLUG:-SideTabExp}"
EXP_BUNDLE_ID="${SIDESCREEN_EXP_BUNDLE_ID:-com.sidescreen.app.experimental}"
EXP_ROOT="${SIDESCREEN_EXP_ROOT:-$HOME/Applications-Experimental}"
EXP_APP="$EXP_ROOT/$EXP_NAME.app"

DO_BUILD=1
DO_LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --no-launch) DO_LAUNCH=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Refuse to run if the experimental paths could ever resolve onto the live app.
for path in "$EXP_APP" "$EXP_ROOT"; do
    case "$path" in
        "$HOME/Applications/SideScreen.app"|"$HOME/Applications")
            echo "Refusing to touch the live install path: $path" >&2
            exit 1
            ;;
    esac
done
if [ "$EXP_BUNDLE_ID" = "com.sidescreen.app" ]; then
    echo "Refusing to reuse the live bundle identifier." >&2
    exit 1
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo "==> Building (this does not install or touch the live app)"
    "$ROOT_DIR/scripts/build_mac.sh"
fi

SOURCE_APP="$ROOT_DIR/SideScreen.app"
if [ ! -d "$SOURCE_APP" ]; then
    echo "Missing build: $SOURCE_APP" >&2
    exit 1
fi

echo "==> Preparing experimental bundle: $EXP_NAME ($EXP_BUNDLE_ID)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/$EXP_NAME.app"
ditto --rsrc --extattr --qtn "$SOURCE_APP" "$STAGED_APP"

# Distinct identity. The name must match the designated requirement below or
# signing fails, and the identifier must differ or the two apps share TCC state.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $EXP_BUNDLE_ID" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $EXP_NAME" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $EXP_NAME" "$STAGED_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $EXP_NAME" "$STAGED_APP/Contents/Info.plist"

# Re-sign with a requirement scoped to the experimental identity, mirroring what
# sign_mac_app.sh does for the live app. Without this the ad-hoc signature's
# CDHash changes on every rebuild and macOS forgets the Screen Recording grant.
IDENTITY="${SIDESCREEN_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*Apple Development.*\)"/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
    echo "No codesigning identity found; falling back to ad-hoc." >&2
    IDENTITY="-"
fi
ENTITLEMENTS="$ROOT_DIR/MacHost/SideScreen.entitlements"
REQ="=designated => identifier \"$EXP_BUNDLE_ID\" and info[CFBundleName] = \"$EXP_NAME\""
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --timestamp=none -r "$REQ" "$STAGED_APP"
else
    codesign --force --sign "$IDENTITY" --timestamp=none -r "$REQ" "$STAGED_APP"
fi
if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$STAGED_APP" 2>/dev/null \
        || codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP" && echo "    signature valid"

# Keep any previous experimental build recoverable rather than deleting it.
if [ -d "$EXP_APP" ]; then
    PREV="$EXP_APP.previous.$(date +%Y%m%d%H%M%S)"
    mv "$EXP_APP" "$PREV"
    echo "    previous experimental build kept at $(basename "$PREV")"
fi
mkdir -p "$EXP_ROOT"
ditto --rsrc --extattr --qtn "$STAGED_APP" "$EXP_APP"
echo "    installed: $EXP_APP"

cat <<EOF

Experimental build installed.

  live app        $LIVE_APP   (untouched)
  experimental    $EXP_APP
  bundle id       $EXP_BUNDLE_ID   (separate UserDefaults + TCC identity)

The experimental build will need its own Screen Recording and Accessibility
grants the first time you use it. That is intentional — it keeps the two apps
from sharing TCC state, which is the whole point.

EOF

if [ "$DO_LAUNCH" -eq 1 ]; then
    echo "==> Launching experimental build"
    open -a "$EXP_APP"
fi
