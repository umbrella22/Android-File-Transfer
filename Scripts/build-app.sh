#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
INSTALL="${2:-}"
APP_NAME="Android File Transfer"
EXECUTABLE="AndroidFileTransferApp"
APP_DIR="dist/${APP_NAME}.app"

swift build -c "$CONFIG"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/${CONFIG}/${EXECUTABLE}" "$APP_DIR/Contents/MacOS/${EXECUTABLE}"
cp "AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "AppBundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
for lproj in AppBundle/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP_DIR/Contents/Resources/"
done

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"

if [[ "$INSTALL" == "--install" ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/${APP_NAME}.app"
    cp -R "$APP_DIR" "$INSTALL_DIR/${APP_NAME}.app"
    echo "Installed $INSTALL_DIR/${APP_NAME}.app"
fi
