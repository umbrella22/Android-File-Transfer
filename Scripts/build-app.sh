#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
if (( $# > 0 )); then
    shift
fi
INSTALL=false
BUILD_ARGS=(-c "$CONFIG")
for option in "$@"; do
    case "$option" in
        --install) INSTALL=true ;;
        --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
        *)
            echo "Usage: $0 [debug|release] [--install] [--universal]" >&2
            exit 1
            ;;
    esac
done
APP_NAME="Android File Transfer"
EXECUTABLE="AndroidFileTransferApp"
APP_DIR="dist/${APP_NAME}.app"

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "${BIN_DIR}/${EXECUTABLE}" "$APP_DIR/Contents/MacOS/${EXECUTABLE}"
cp "AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "AppBundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
for lproj in AppBundle/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP_DIR/Contents/Resources/"
done

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"

if [[ "$INSTALL" == true ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/${APP_NAME}.app"
    cp -R "$APP_DIR" "$INSTALL_DIR/${APP_NAME}.app"
    echo "Installed $INSTALL_DIR/${APP_NAME}.app"
fi
