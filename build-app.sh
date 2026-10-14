#!/bin/bash
# Build Y1 Sync.app as a double-clickable bundle.
#
# SwiftPM produces a bare executable; macOS needs an .app layout with an
# Info.plist before it will run as a windowed app (and before the window can
# take focus at all).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
APP_NAME="Y1 Sync"
BUNDLE_ID="local.y1sync"
OUT_DIR="${1:-build}"
APP="$OUT_DIR/$APP_NAME.app"

# Optional switches (used by release.sh):
#   UNIVERSAL=1   build for both Apple silicon and Intel
#   SKIP_SOUNDS=1 leave the third-party UI sounds out of the bundle
#   VERSION=1.2   version shown in the app's Info.plist
VERSION="${VERSION:-1.0}"
ARCH_FLAGS=()
PRODUCTS_DIR=".build/$CONFIG"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Y1SyncApp
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product y1sync

if [ "${UNIVERSAL:-0}" = "1" ]; then
    PRODUCTS_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"
fi
BIN="$PRODUCTS_DIR/Y1SyncApp"
CLI="$PRODUCTS_DIR/y1sync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Y1SyncApp"
cp "$CLI" "$OUT_DIR/y1sync"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Fonts and UI sounds are loaded from Contents/Resources at run time (they are
# deliberately not SwiftPM resources — see Theme/ResourceLocator.swift).
for dir in Fonts Sounds; do
    if [ -d "Resources/$dir" ]; then
        cp -R "Resources/$dir" "$APP/Contents/Resources/$dir"
    fi
done
if [ "${SKIP_SOUNDS:-0}" = "1" ]; then
    rm -f "$APP"/Contents/Resources/Sounds/*.mp3 "$APP"/Contents/Resources/Sounds/*.wav \
          "$APP"/Contents/Resources/Sounds/*.aif "$APP"/Contents/Resources/Sounds/*.m4a
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>Y1SyncApp</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Regular app: without this the process has no Dock icon and the
         window cannot become key. -->
    <key>LSUIElement</key>             <false/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: unsigned bundles are killed on launch on Apple silicon.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "note: ad-hoc codesign failed; the app may need a right-click > Open"

echo
echo "Built: $APP"
echo "CLI:   $OUT_DIR/y1sync"
echo
echo "Run it with:  open '$APP'"
