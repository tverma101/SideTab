#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
APK_METADATA="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/output-metadata.json"
MAC_APP="$ROOT_DIR/SideScreen.app"
MAC_DMG="$ROOT_DIR/dist/current/SideScreen-${VERSION}-mac-universal.dmg"
MAC_BUILD_MANIFEST="$ROOT_DIR/dist/current/BUILD-MANIFEST.txt"
OUTPUT_DIR="$ROOT_DIR/artifacts/SideScreen-${VERSION}"

if [ ! -f "$APK_PATH" ] || [ ! -f "$APK_METADATA" ]; then
    echo "Current debug APK is missing. Run ./scripts/build_android.sh first." >&2
    exit 1
fi
if [ ! -f "$MAC_DMG" ] || [ ! -f "$MAC_BUILD_MANIFEST" ]; then
    echo "Current Mac DMG is missing. Run ./scripts/build_mac.sh first." >&2
    exit 1
fi
if [ ! -d "$MAC_APP" ]; then
    echo "Current SideScreen.app build is missing: $MAC_APP" >&2
    exit 1
fi
if [ -e "$OUTPUT_DIR/SideScreen.app" ]; then
    echo "A duplicate SideScreen.app is present in $OUTPUT_DIR." >&2
    echo "The DMG is the Mac installer; move the duplicate app bundle to Trash first." >&2
    exit 1
fi

APK_METADATA_VALUES="$(python3 - "$APK_METADATA" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
element = data["elements"][0]
print(data["applicationId"], element["versionCode"], element["versionName"])
PY
)"
read -r APPLICATION_ID VERSION_CODE VERSION_NAME <<< "$APK_METADATA_VALUES"
if [ "$APPLICATION_ID" != "com.sidescreen.app" ] || [ "$VERSION_NAME" != "$VERSION" ]; then
    echo "APK metadata does not match this SideTab source version." >&2
    echo "  applicationId=$APPLICATION_ID versionName=$VERSION_NAME expected=$VERSION" >&2
    exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
MAC_COMMIT="$(sed -n 's/^source_commit=//p' "$MAC_BUILD_MANIFEST" | head -n 1)"
if [ "$MAC_COMMIT" != "$SOURCE_COMMIT" ]; then
    echo "Mac DMG was built from $MAC_COMMIT, current checkout is $SOURCE_COMMIT." >&2
    echo "Rebuild the Mac app before packaging both installers together." >&2
    exit 1
fi

if [ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]; then
    SOURCE_TREE_STATE="clean"
else
    SOURCE_TREE_STATE="dirty"
fi
SOURCE_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
BUILD_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

codesign --verify --deep --strict "$MAC_APP"
ARCHITECTURES="$(lipo -archs "$MAC_APP/Contents/MacOS/SideScreen")"
case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) echo "Mac app is missing arm64: $ARCHITECTURES" >&2; exit 1 ;;
esac
case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) echo "Mac app is missing x86_64: $ARCHITECTURES" >&2; exit 1 ;;
esac
hdiutil verify "$MAC_DMG" >/dev/null

mkdir -p "$OUTPUT_DIR"
cp "$APK_PATH" "$OUTPUT_DIR/SideScreen-${VERSION}-android-debug.apk"
cp "$MAC_DMG" "$OUTPUT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
APK_SHA="$(shasum -a 256 "$OUTPUT_DIR/SideScreen-${VERSION}-android-debug.apk" | awk '{print $1}')"
DMG_SHA="$(shasum -a 256 "$OUTPUT_DIR/SideScreen-${VERSION}-mac-universal.dmg" | awk '{print $1}')"

cat > "$OUTPUT_DIR/MANIFEST.txt" <<EOF
SideTab local validation package
version=$VERSION
source_commit=$SOURCE_COMMIT
source_branch=$SOURCE_BRANCH
source_tree=$SOURCE_TREE_STATE
built_utc=$BUILD_UTC

[android]
file=SideScreen-${VERSION}-android-debug.apk
variant=debug
application_id=$APPLICATION_ID
version_code=$VERSION_CODE
version_name=$VERSION_NAME
sha256=$APK_SHA

[macos]
file=SideScreen-${VERSION}-mac-universal.dmg
bundle_id=com.sidescreen.app
version=$VERSION
architectures=$ARCHITECTURES
sha256=$DMG_SHA
validation=hdiutil verify; codesign and architecture validation passed

The Mac installer is the DMG above. The Android source APK is
AndroidClient/app/build/outputs/apk/debug/app-debug.apk.
EOF

echo "Current Mac installer: $OUTPUT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
echo "Current Android APK:   $OUTPUT_DIR/SideScreen-${VERSION}-android-debug.apk"
echo "Manifest:              $OUTPUT_DIR/MANIFEST.txt"
