#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}"
# Strip leading v
VERSION="${VERSION#v}"
OUT_DIR="${ROOT}/dist"
APP_NAME="MacStorageStudio"
APP_PATH="${OUT_DIR}/${APP_NAME}.app"
ZIP_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}-macos-arm64.zip"

echo "==> Building release binaries"
swift build -c release --product MacStorageStudio
swift build -c release --product ScannerWorker

BUILD_DIR="${ROOT}/.build/release"
WORKER="${BUILD_DIR}/ScannerWorker"
APP_BIN="${BUILD_DIR}/MacStorageStudio"

test -x "$WORKER"
test -x "$APP_BIN"

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_PATH"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

cp "$APP_BIN" "${APP_PATH}/Contents/MacOS/MacStorageStudio"
cp "$WORKER" "${APP_PATH}/Contents/MacOS/ScannerWorker"
chmod +x "${APP_PATH}/Contents/MacOS/MacStorageStudio" "${APP_PATH}/Contents/MacOS/ScannerWorker"

# Info.plist with version
PLIST="${APP_PATH}/Contents/Info.plist"
cp "${ROOT}/App/MacStorageStudio/Resources/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.macstoragestudio.app" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.macstoragestudio.app" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable MacStorageStudio" "$PLIST" 2>/dev/null || true

# Ad-hoc sign for local gatekeeper friendliness (not notarized)
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true

echo "==> Zipping"
rm -f "$ZIP_PATH"
(
  cd "$OUT_DIR"
  ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$(basename "$ZIP_PATH")"
)

# SHA256
shasum -a 256 "$ZIP_PATH" | tee "${ZIP_PATH}.sha256"

echo "==> Artifacts"
ls -lh "$APP_PATH" "$ZIP_PATH" "${ZIP_PATH}.sha256"
echo "ZIP_PATH=${ZIP_PATH}"
echo "VERSION=${VERSION}"
