#!/bin/bash
# Double-click in Finder: builds the app + CLI and runs the tests.
# Full output is also saved to check-log.txt next to this file.
cd "$(dirname "$0")"

# Tests need XCTest, which ships only with full Xcode (not the Command Line
# Tools). Find Xcode wherever it is installed, whatever it is called.
XCODE=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)
if [ -n "$XCODE" ]; then
  export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
{
  echo "=== $(date) ==="
  echo "Toolchain: ${DEVELOPER_DIR:-$(xcode-select -p)}"
  swift --version 2>&1 | head -1
  echo "=== build-app.sh ==="
  ./build-app.sh
  echo "BUILD_EXIT=$?"
  echo "=== swift test ==="
  if [ -z "$XCODE" ]; then
    echo "SKIPPED: Xcode not found — tests need XCTest, which only full Xcode includes."
  else
    swift test --scratch-path "$HOME/Library/Caches/Y1Sync-test-build" 2>&1 | grep -E "error:|failed|Executed|Test Suite 'All tests'|detritus" | tail -80
    echo "TEST_EXIT=${PIPESTATUS[0]}"
  fi
  echo "=== DONE ==="
} 2>&1 | tee check-log.txt
