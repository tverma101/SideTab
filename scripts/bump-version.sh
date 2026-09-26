#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "Current version: $CURRENT_VERSION"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "${1:-patch}" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

# VERSION is the canonical version input. Keep the static source plist in sync
# for tools that inspect it outside the generated app bundle.
PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [ ! -x "$PLIST_BUDDY" ]; then
    echo "Error: macOS PlistBuddy is required to update MacHost/Info.plist" >&2
    exit 1
fi

"$PLIST_BUDDY" -c "Set :CFBundleVersion $NEW_VERSION" "$ROOT_DIR/MacHost/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $NEW_VERSION" "$ROOT_DIR/MacHost/Info.plist"
echo "$NEW_VERSION" > "$VERSION_FILE"

echo ""
echo "  $CURRENT_VERSION -> $NEW_VERSION"
echo ""
echo "Review CHANGELOG.md, then inspect the version metadata diff before building."
