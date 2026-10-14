#!/bin/bash
# Build the release files: a universal (Apple silicon + Intel) app and CLI, zipped,
# without the third-party UI sounds. Usage: ./release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")"

# Universal builds need the full Xcode toolchain (the Command Line Tools cannot).
XCODE=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)
if [ -n "$XCODE" ]; then export DEVELOPER_DIR="$XCODE/Contents/Developer"; fi

VERSION="${1:?usage: ./release.sh <version>, e.g. 1.0.0}"
OUT="dist"
rm -rf "$OUT"; mkdir -p "$OUT"

UNIVERSAL=1 SKIP_SOUNDS=1 VERSION="$VERSION" ./build-app.sh "$OUT/stage"

ditto -c -k --keepParent "$OUT/stage/Y1 Sync.app" "$OUT/Y1-Sync-$VERSION-macOS.zip"
ditto -c -k "$OUT/stage/y1sync" "$OUT/y1sync-$VERSION-macOS.zip"
rm -rf "$OUT/stage"

echo
(cd "$OUT" && shasum -a 256 *.zip | tee SHA256SUMS.txt)
