#!/usr/bin/env python3
"""Sign the release DMG and its Sparkle feed with the project's Ed25519 key."""
import base64
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / 'dist'
DMG = 'Android-File-Transfer-macOS-universal.dmg'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run():
    tag = sys.argv[1]
    info = plistlib.loads((DIST / 'Android File Transfer.app/Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if tag != f'v{version}' or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
        sys.exit(f'Tag {tag} must match the bundle version {version}')
    repo = os.environ.get('GITHUB_REPOSITORY', 'umbrella22/Android-File-Transfer')
    releases = f'https://github.com/{repo}/releases/'
    if info['SUFeedURL'] != releases + 'latest/download/appcast.xml':
        sys.exit('Bundle feed URL does not match the publishing repository')
    prefix = f'{releases}download/{tag}/'
    key = os.environ.pop('SPARKLE_PRIVATE_ED_KEY', '').strip().encode()
    if not key:
        sys.exit('Missing SPARKLE_PRIVATE_ED_KEY')
    tools, = (ROOT / '.build/artifacts').glob('*/Sparkle/bin/generate_appcast')
    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        # Only this release belongs in the feed, even when dist has old build products.
        archive = staging / DMG
        shutil.copyfile(DIST / DMG, archive)
        feed = staging / 'appcast.xml'
        subprocess.run([tools, '--ed-key-file', '-', '--download-url-prefix', prefix,
                        '--maximum-deltas', '0', '-o', feed, staging], input=key, check=True)
        subprocess.run([tools.with_name('sign_update'), '--ed-key-file', '-', '--verify', feed], input=key, check=True)
        item, = ET.parse(feed).findall('./channel/item')
        enclosure = item.find('enclosure')
        if (item.findtext(NS + 'version') != info['CFBundleVersion']
                or item.findtext(NS + 'shortVersionString') != version
                or enclosure is None or enclosure.get('url') != prefix + DMG
                or enclosure.get('length') != str(archive.stat().st_size)):
            sys.exit('Appcast version, download URL or archive length mismatch')
        signature = enclosure.attrib[NS + 'edSignature']
        if len(base64.b64decode(signature, validate=True)) != 64:
            sys.exit('Invalid release signature')
        subprocess.run(['swift', ROOT / 'Scripts/verify-update.swift', info['SUPublicEDKey'], signature, archive], check=True)
        output = DIST / 'appcast.xml'
        output.write_bytes(feed.read_bytes())


if __name__ == '__main__':
    run()
