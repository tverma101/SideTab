#!/usr/bin/env bash
set -euo pipefail

# Install exactly one user-facing host bundle. The old installer renamed every
# existing bundle to SideScreen.app.previous.<timestamp>, which accumulated
# dozens of full app copies. Replace the verified target in place instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="${HOME:?HOME is not set}"
SOURCE_APP="$ROOT_DIR/SideScreen.app"
INSTALL_ROOT="${SIDESCREEN_INSTALL_ROOT:-$USER_HOME/Applications}"
TARGET_APP="${SIDESCREEN_INSTALL_APP:-$INSTALL_ROOT/SideScreen.app}"
LAUNCH=false

usage() {
    echo "Usage: $0 [--launch]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --launch)
            LAUNCH=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$SOURCE_APP" ]; then
    echo "Missing current build: $SOURCE_APP" >&2
    echo "Run ./scripts/build_mac.sh first." >&2
    exit 1
fi

source_bundle_id=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$source_bundle_id" != "com.sidescreen.app" ]; then
    echo "Refusing to install an unexpected bundle: $SOURCE_APP" >&2
    exit 1
fi

if [ "$SOURCE_APP" = "$TARGET_APP" ]; then
    echo "Source and install target are the same path; nothing to install." >&2
    exit 2
fi

mkdir -p "$INSTALL_ROOT"

if [ -L "$TARGET_APP" ]; then
    echo "Refusing to replace symlink target: $TARGET_APP" >&2
    exit 1
fi

target_bundle_id=""
if [ -e "$TARGET_APP" ]; then
    if [ ! -d "$TARGET_APP" ]; then
        echo "Refusing to replace non-directory target: $TARGET_APP" >&2
        exit 1
    fi
    target_bundle_id=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)
    if [ "$target_bundle_id" != "com.sidescreen.app" ]; then
        echo "Refusing to replace an unexpected app at: $TARGET_APP" >&2
        exit 1
    fi
fi

running_pids() {
    local app_path="$1"
    ps -axo pid=,command= 2>/dev/null | awk -v prefix="$app_path/Contents/MacOS/SideScreen" '
        {
            pid = $1
            $1 = ""
            sub(/^[[:space:]]+/, "")
            if (index($0, prefix) == 1) {
                print pid
            }
        }
    '
}

if [ -e "$TARGET_APP" ]; then
    for pid in $(running_pids "$TARGET_APP"); do
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) kill -TERM "$pid" 2>/dev/null || true ;;
        esac
    done

    attempts=0
    while [ "$attempts" -lt 30 ] && [ -n "$(running_pids "$TARGET_APP")" ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    if [ -n "$(running_pids "$TARGET_APP")" ]; then
        echo "The current SideScreen install did not stop; refusing to replace it." >&2
        exit 1
    fi
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sidescreen-install.XXXXXX")"
cleanup() {
    if [ -n "${TEMP_ROOT:-}" ] && [ -d "$TEMP_ROOT" ]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

ditto --rsrc --extattr --qtn "$SOURCE_APP" "$TEMP_ROOT/SideScreen.app"
"$SCRIPT_DIR/sign_mac_app.sh" "$TEMP_ROOT/SideScreen.app"

OLD_TARGET="$TEMP_ROOT/previous.app"
if [ -e "$TARGET_APP" ]; then
    mv "$TARGET_APP" "$OLD_TARGET"
fi

if ! mv "$TEMP_ROOT/SideScreen.app" "$TARGET_APP"; then
    if [ -e "$OLD_TARGET" ] && [ ! -e "$TARGET_APP" ]; then
        mv "$OLD_TARGET" "$TARGET_APP"
    fi
    echo "Failed to install the new SideScreen bundle; the previous target was restored when possible." >&2
    exit 1
fi

# The old target is the exact verified SideScreen install, and the replacement
# is already in place. Remove the staging copy so no backup is left behind.
if [ -e "$OLD_TARGET" ]; then
    rm -rf "$OLD_TARGET"
fi

codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
"$SCRIPT_DIR/cleanup_old_app_copies.sh" --apply --install-root "$INSTALL_ROOT"

echo "Installed current host: $TARGET_APP"
echo "No previous app snapshot was created."

if [ "$LAUNCH" = true ]; then
    /usr/bin/open -n "$TARGET_APP"
fi
