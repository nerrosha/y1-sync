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

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product Y1SyncApp
swift build -c "$CONFIG" --product y1sync

BIN=".build/$CONFIG/Y1SyncApp"
CLI=".build/$CONFIG/y1sync"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
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
