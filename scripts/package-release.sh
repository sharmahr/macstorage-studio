#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
OUT_DIR="${ROOT}/dist"
APP_NAME="MacStorage Studio"
APP_PATH="${OUT_DIR}/${APP_NAME}.app"
ZIP_PATH="${OUT_DIR}/MacStorageStudio-${VERSION}-macos-arm64.zip"

echo "==> Building release binaries"
swift build -c release --product MacStorageStudio
swift build -c release --product ScannerWorker

BUILD_DIR="${ROOT}/.build/release"
WORKER="${BUILD_DIR}/ScannerWorker"
APP_BIN="${BUILD_DIR}/MacStorageStudio"

test -x "$WORKER"
test -x "$APP_BIN"

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_PATH" "${OUT_DIR}/MacStorageStudio.app"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

cp "$APP_BIN" "${APP_PATH}/Contents/MacOS/MacStorageStudio"
cp "$WORKER" "${APP_PATH}/Contents/MacOS/ScannerWorker"
chmod +x "${APP_PATH}/Contents/MacOS/MacStorageStudio" "${APP_PATH}/Contents/MacOS/ScannerWorker"
cp "${ROOT}/App/MacStorageStudio/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"

PLIST="${APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.macstoragestudio.app" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName MacStorage Studio" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MacStorage Studio" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable MacStorageStudio" "$PLIST" 2>/dev/null || true

codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true
ln -sfn "${APP_NAME}.app" "${OUT_DIR}/MacStorageStudio.app"

echo "==> Zipping"
rm -f "$ZIP_PATH"
(
  cd "$OUT_DIR"
  ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$(basename "$ZIP_PATH")"
)

shasum -a 256 "$ZIP_PATH" | tee "${ZIP_PATH}.sha256"
echo "ZIP_PATH=${ZIP_PATH}"
echo "VERSION=${VERSION}"
