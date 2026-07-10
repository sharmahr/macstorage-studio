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

APP_ROOT="$ROOT/dist/MacStorageStudio.app/Contents"
rm -rf "$ROOT/dist/MacStorageStudio.app"
mkdir -p "$APP_ROOT/MacOS" "$APP_ROOT/Resources"

cp "$BUILD_DIR/MacStorageStudio" "$APP_ROOT/MacOS/MacStorageStudio"
cp "$BUILD_DIR/ScannerWorker" "$APP_ROOT/MacOS/ScannerWorker"
cp "$ROOT/App/MacStorageStudio/Resources/Info.plist" "$APP_ROOT/Info.plist"
# Patch executable name already correct

# Ad-hoc sign for local run
codesign --force --deep --sign - "$ROOT/dist/MacStorageStudio.app" 2>/dev/null || true

echo "==> Built $ROOT/dist/MacStorageStudio.app"
echo "    ScannerWorker: $APP_ROOT/MacOS/ScannerWorker"
echo "    Run: open dist/MacStorageStudio.app"
echo "    Or:  MACSTORAGE_SCANNER_WORKER=$APP_ROOT/MacOS/ScannerWorker $APP_ROOT/MacOS/MacStorageStudio"
