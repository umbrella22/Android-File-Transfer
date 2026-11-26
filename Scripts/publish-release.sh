#!/bin/bash
set -euo pipefail
: "${RELEASE_TAG:?}" "${GH_REPO:?}"
assets=(dist/Android-File-Transfer-macOS-universal.dmg dist/SHA256SUMS dist/appcast.xml)
# Stage every asset before making the new latest/download/appcast.xml visible to clients.
if status=$(gh release view "$RELEASE_TAG" --json isDraft --jq '.isDraft'); then
    if [[ "$status" == false ]]; then
        echo "Release $RELEASE_TAG is already published. Its signed assets are immutable."
        exit 0
    fi
else
    gh release create "$RELEASE_TAG" --draft --verify-tag --title "$RELEASE_TAG" --generate-notes
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
latest=$(gh api "repos/$GH_REPO/releases/latest" --jq '.tag_name')
if [[ -n "$latest" ]]; then
    if [[ "$latest" != v0.1.1 ]]; then
        gh release download "$latest" --pattern appcast.xml --dir "$tmp"
    fi
    python3 - "$latest" "$RELEASE_TAG" "$tmp/appcast.xml" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
old, new, previous = sys.argv[1:]
if tuple(map(int, new[1:].split('.'))) <= tuple(map(int, old[1:].split('.'))):
    sys.exit('The new release must advance the latest stable version')
key = './channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version'
if pathlib.Path(previous).exists() and int(ET.parse('dist/appcast.xml').findtext(key)) <= int(ET.parse(previous).findtext(key)):
    sys.exit('Increment CFBundleVersion before publishing the update')
PY
fi
gh release upload "$RELEASE_TAG" "${assets[@]}" --clobber
gh release edit "$RELEASE_TAG" --draft=false --latest
