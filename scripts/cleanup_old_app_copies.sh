#!/usr/bin/env bash
set -euo pipefail

# Remove only SideScreen installer snapshots from the user install directory.
# The helper is intentionally narrow: it does not search the whole disk, touch
# other applications, or empty the Trash.
INSTALL_ROOT="${SIDESCREEN_INSTALL_ROOT:-${HOME:?HOME is not set}/Applications}"
MODE="dry-run"

usage() {
    cat <<'USAGE'
Usage: cleanup_old_app_copies.sh [--dry-run|--apply] [--install-root PATH]

Finds SideScreen.app.previous.<timestamp> bundles in the selected install
directory. Dry-run is the default. --apply moves verified stale bundles to the
macOS Trash; it never empties the Trash or deletes unrelated applications.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --apply)
            MODE="apply"
            shift
            ;;
        --install-root)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --install-root" >&2
                usage >&2
                exit 2
            fi
            INSTALL_ROOT="$2"
            shift 2
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

if [ ! -d "$INSTALL_ROOT" ]; then
    echo "No macOS install directory: $INSTALL_ROOT"
    exit 0
fi

if [ "$MODE" = "apply" ] && [ ! -x /usr/bin/trash ]; then
    echo "macOS Trash tool is unavailable; refusing to delete app copies." >&2
    exit 1
fi

bundle_identifier() {
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$1/Contents/Info.plist" 2>/dev/null || true
}

is_running_from_bundle() {
    local app_path="$1"
    local process_line

    while IFS= read -r process_line; do
        case "$process_line" in
            *"$app_path/Contents/MacOS/SideScreen"*)
                return 0
                ;;
        esac
    done <<EOF
$(ps -axo pid=,command= 2>/dev/null || true)
EOF
    return 1
}

found_count=0
moved_count=0
skipped_count=0

while IFS= read -r -d '' app_path; do
    found_count=$((found_count + 1))

    if [ ! -f "$app_path/Contents/Info.plist" ]; then
        skipped_count=$((skipped_count + 1))
        echo "Skipping invalid app bundle: $app_path"
        continue
    fi

    if [ "$(bundle_identifier "$app_path")" != "com.sidescreen.app" ]; then
        skipped_count=$((skipped_count + 1))
        echo "Skipping non-SideScreen bundle: $app_path"
        continue
    fi

    if is_running_from_bundle "$app_path"; then
        skipped_count=$((skipped_count + 1))
        echo "Skipping running bundle: $app_path"
        continue
    fi

    if [ "$MODE" = "dry-run" ]; then
        echo "Would move to Trash: $app_path"
    else
        /usr/bin/trash "$app_path"
        moved_count=$((moved_count + 1))
        echo "Moved to Trash: $app_path"
    fi
done < <(find "$INSTALL_ROOT" -maxdepth 1 -type d -name 'SideScreen.app.previous.*' -print0)

if [ "$MODE" = "dry-run" ]; then
    echo "Found $found_count stale snapshot(s); $skipped_count skipped."
    echo "Dry run only. Re-run with --apply to move verified snapshots to Trash."
else
    echo "Moved $moved_count stale snapshot(s) to Trash; $skipped_count skipped."
    echo "Trash was not emptied."
fi
