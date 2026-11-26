#!/usr/bin/env python3
"""Install and relaunch an isolated ad-hoc app via Sparkle using a one-run signing key."""
import functools
import http.server
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'dist/Android File Transfer.app'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def smoke(work, server):
    port = server.server_address[1]
    prefix = f'http://127.0.0.1:{port}/'
    host = work / 'installed/SparkleSmoke.app'
    host.parent.mkdir()
    public_dir = work / 'www'
    framework = APP / 'Contents/Frameworks/Sparkle.framework'
    contents = host / 'Contents'
    run('ditto', framework, contents / 'Frameworks/Sparkle.framework')
    (contents / 'MacOS').mkdir()
    run('clang', '-fobjc-arc', '-framework', 'AppKit', '-F', framework.parent, '-framework', 'Sparkle',
        '-Wl,-rpath,@executable_path/../Frameworks', ROOT / 'Scripts/tests/updater-host.m', '-o', contents / 'MacOS/Smoke')
    # Only the disposable fixture uses this key and loopback feed. Release credentials are never needed.
    key = work / 'test.key'
    generator = '''import CryptoKit; import Foundation
let k = Curve25519.Signing.PrivateKey()
try k.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(k.publicKey.rawRepresentation.base64EncodedString())'''
    public = run('swift', '-e', generator, str(key), capture_output=True, text=True).stdout.strip()
    base = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    fields = {k: base[k] for k in ['SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed', 'LSMinimumSystemVersion', 'CFBundlePackageType']}
    fields.update(CFBundleIdentifier='com.androidfiletransfer.test.' + uuid.uuid4().hex, CFBundleExecutable='Smoke',
                  CFBundleName='SparkleSmoke', CFBundleVersion='1', CFBundleShortVersionString='1.0', LSUIElement=True,
                  SUEnableAutomaticChecks=False, SUPublicEDKey=public, SUFeedURL=prefix + 'appcast.xml')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(fields))
    run('codesign', '--force', '--sign', '-', host)
    newer = work / 'new/SparkleSmoke.app'
    run('ditto', host, newer)
    fields.update(CFBundleVersion='2', CFBundleShortVersionString='2.0')
    (newer / 'Contents/Info.plist').write_bytes(plistlib.dumps(fields))
    run('codesign', '--force', '--sign', '-', newer)
    archive = public_dir / 'update.dmg'
    run('hdiutil', 'create', '-quiet', '-format', 'UDZO', '-volname', 'UpdateSmoke', '-srcfolder', newer.parent, archive)
    tool, = (ROOT / '.build/artifacts').glob('*/Sparkle/bin/generate_appcast')
    run(tool, '--ed-key-file', key, '--download-url-prefix', prefix, '--maximum-deltas', '0', public_dir)
    feed = public_dir / 'appcast.xml'
    signature = ET.parse(feed).find('./channel/item/enclosure').attrib[NS + 'edSignature']
    run('swift', ROOT / 'Scripts/verify-update.swift', public, signature, archive)
    damaged = work / 'damaged.dmg'
    shutil.copyfile(archive, damaged)
    with damaged.open('ab') as stream:
        stream.write(b'x')
    if subprocess.run(['swift', ROOT / 'Scripts/verify-update.swift', public, signature, damaged]).returncode == 0:
        raise RuntimeError('Accepted damaged archive')
    # Sparkle stores its signature as an XML comment outside the signed document.
    bad_feed = work / 'tampered.xml'
    bad_feed.write_bytes(feed.read_bytes().replace(b'update.dmg', b'changed.dmg'))
    if subprocess.run([tool.with_name('sign_update'), '--ed-key-file', key, '--verify', bad_feed]).returncode == 0:
        raise RuntimeError('Accepted modified feed')
    with (work / 'host.log').open('w') as log:
        process = subprocess.Popen([contents / 'MacOS/Smoke'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 90
            receipt = host.parent / 'relaunched'
            while not receipt.exists():
                if process.poll() not in (None, 0) or time.monotonic() > deadline:
                    raise RuntimeError((work / 'host.log').read_text() + '\nSparkle did not relaunch the installed update')
                time.sleep(0.3)
            assert receipt.read_text() == '2' and plistlib.loads((contents / 'Info.plist').read_bytes())['CFBundleVersion'] == '2'
            run('codesign', '--verify', '--deep', '--strict', host)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    print('PASS: ad-hoc build 1 updated to build 2 and relaunched. Corrupted feed and DMG rejected.')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='aft-sparkle-') as tmp:
        work = Path(tmp)
        (work / 'www').mkdir()
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=work / 'www')
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                smoke(work, server)
            finally:
                server.shutdown()
