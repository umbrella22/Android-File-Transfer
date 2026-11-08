#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo "DMG packaging requires macOS." >&2
    exit 1
fi

TOOLS_DIR=".build/dmg-tools"
if [[ ! -x "$TOOLS_DIR/bin/python" ]]; then
    python3 -m venv "$TOOLS_DIR"
fi
"$TOOLS_DIR/bin/python" -m pip install --disable-pip-version-check \
    -r Scripts/requirements-dmg.txt

exec "$TOOLS_DIR/bin/python" Scripts/build-dmg.py "$@"
