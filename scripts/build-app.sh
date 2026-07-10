#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-debug}"

echo "==> swift build ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product MacStorageStudio
  swift build -c release --product ScannerWorker
  BUILD_DIR="$ROOT/.build/release"
else
  swift build --product MacStorageStudio
  swift build --product ScannerWorker
  BUILD_DIR="$ROOT/.build/debug"
fi

# Prefer spaced name for System Settings display
APP_NAME="MacStorage Studio.app"
APP_PATH="$ROOT/dist/$APP_NAME"
rm -rf "$APP_PATH" "$ROOT/dist/MacStorageStudio.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BUILD_DIR/MacStorageStudio" "$APP_PATH/Contents/MacOS/MacStorageStudio"
cp "$BUILD_DIR/ScannerWorker" "$APP_PATH/Contents/MacOS/ScannerWorker"
chmod +x "$APP_PATH/Contents/MacOS/MacStorageStudio" "$APP_PATH/Contents/MacOS/ScannerWorker"
cp "$ROOT/App/MacStorageStudio/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

# Ensure stable identity for Full Disk Access
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.macstoragestudio.app" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName MacStorage Studio" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MacStorage Studio" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true

codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true

# Compatibility symlink name without spaces
ln -sfn "$APP_NAME" "$ROOT/dist/MacStorageStudio.app"

echo "==> Built $APP_PATH"
echo "    Run: open \"dist/MacStorage Studio.app\""
