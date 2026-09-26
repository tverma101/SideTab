#!/usr/bin/env bash
set -euo pipefail

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: VERSION must use major.minor.patch, got '$VERSION'" >&2
  exit 1
fi

PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [ ! -x "$PLIST_BUDDY" ]; then
  echo "Error: macOS PlistBuddy is required to validate MacHost/Info.plist" >&2
  exit 1
fi
PLIST_VERSION=$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/MacHost/Info.plist")
PLIST_BUILD_VERSION=$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$ROOT_DIR/MacHost/Info.plist")
if [[ "$PLIST_VERSION" != "$VERSION" || "$PLIST_BUILD_VERSION" != "$VERSION" ]]; then
  echo "Error: MacHost/Info.plist version ($PLIST_VERSION/$PLIST_BUILD_VERSION) does not match VERSION ($VERSION). Run scripts/bump-version.sh or update the plist." >&2
  exit 1
fi

SOURCE_COMMIT=$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
SOURCE_BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
SOURCE_TREE_STATE=dirty
if [ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  SOURCE_TREE_STATE=clean
fi
BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$SOURCE_COMMIT-$$"
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
# Match the executable name only; a broad `pkill -f SideScreen` can also
# match this build script because the checkout path contains SideScreen.
pkill -x SideScreen 2>/dev/null || true
sleep 0.5

# Keep each architecture in its own SwiftPM scratch tree. SwiftPM's current
# `out/Products/Release` layout is shared by sequential `--arch` builds, so a
# single scratch path silently overwrites the first architecture before lipo.
ARM64_SCRATCH=".build/SideScreen-arm64"
X86_64_SCRATCH=".build/SideScreen-x86_64"
mkdir -p .build

# Build fresh (Universal Binary: arm64 + x86_64)
echo "Building macOS Host (arm64)..."
swift build -c release --arch arm64 --scratch-path "$ARM64_SCRATCH"

echo "Building macOS Host (x86_64)..."
swift build -c release --arch x86_64 --scratch-path "$X86_64_SCRATCH"

ARM64_BIN_DIR=$(swift build -c release --arch arm64 --scratch-path "$ARM64_SCRATCH" --show-bin-path)
X86_64_BIN_DIR=$(swift build -c release --arch x86_64 --scratch-path "$X86_64_SCRATCH" --show-bin-path)

echo "Creating Universal Binary..."
mkdir -p ".build/release-universal"
lipo -create \
  "$ARM64_BIN_DIR/SideScreen" \
  "$X86_64_BIN_DIR/SideScreen" \
  -output .build/release-universal/SideScreen

# Create .app bundle
APP_NAME="SideScreen"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary
cp .build/release-universal/SideScreen "$APP_DIR/Contents/MacOS/"

# No LaunchAgent plist needed for SMAppService.mainApp

# Copy app icon if exists
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
EOF

# Keep a stable designated requirement so TCC approval survives rebuilds.
echo "Code signing (stable local identity)..."
"$SCRIPT_DIR/sign_mac_app.sh" "$APP_DIR"
echo "  ✓ App signed"

echo "Cleaning stale installed app snapshots..."
"$SCRIPT_DIR/cleanup_old_app_copies.sh" --apply

echo ""
echo "Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
DMG_DIR=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
OUTPUT_DIR="$ROOT_DIR/dist/SideScreen-${VERSION}/${BUILD_ID}"
mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
hdiutil create -volname "Side Screen" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_DIR"

DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
cat > "$OUTPUT_DIR/BUILD-MANIFEST.txt" << EOF
Side Screen macOS build
version=$VERSION
source_commit=$SOURCE_COMMIT
source_branch=$SOURCE_BRANCH
source_tree=$SOURCE_TREE_STATE
build_utc=$BUILD_UTC
architectures=arm64,x86_64
artifact=$(basename "$DMG_PATH")
sha256=$DMG_SHA256
EOF

# Keep one discoverable entrypoint for the latest successful Mac installer;
# the dated build directories remain available for provenance and rollback.
CURRENT_LINK="$ROOT_DIR/dist/current"
if [ -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
  echo "Refusing to replace non-symlink latest-artifact path: $CURRENT_LINK" >&2
  exit 1
fi
if [ -L "$CURRENT_LINK" ]; then
  rm "$CURRENT_LINK"
fi
ln -s "SideScreen-$VERSION/$BUILD_ID" "$CURRENT_LINK"

echo "DMG: $DMG_PATH"
echo "Latest DMG: $CURRENT_LINK/SideScreen-${VERSION}-mac-universal.dmg"
echo "Manifest: $OUTPUT_DIR/BUILD-MANIFEST.txt"
