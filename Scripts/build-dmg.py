#!/usr/bin/env python3
"""Build and verify the universal app's drag-to-install disk image."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

import dmgbuild
from ds_store import DSStore
from mac_alias import Alias


ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "AppBundle" / "DMG"
APP_NAME = "Android File Transfer.app"
VOLUME_NAME = "Android File Transfer"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_app(app):
    require(app.is_dir(), f"App bundle not found: {app}")
    run("plutil", "-lint", app / "Contents" / "Info.plist")
    run("codesign", "--verify", "--deep", "--strict", app)
    for arch in ("arm64", "x86_64"):
        run("lipo", app / "Contents/MacOS/AndroidFileTransferApp", "-verify_arch", arch)


def verify_image(image, work, layout):
    run("hdiutil", "verify", image)
    result = subprocess.check_output([
        "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
        "-plist", str(image),
    ])
    entities = plistlib.loads(result)["system-entities"]
    device = entities[0]["dev-entry"]
    try:
        mounted = next((entity.get("mount-point") for entity in entities
                        if entity.get("mount-point")), None)
        require(mounted is not None, "DMG did not mount a filesystem")
        mount = Path(mounted)
        applications = mount / "Applications"
        require(applications.is_symlink() and os.readlink(applications) == "/Applications",
                "Applications must link to /Applications")
        require((mount / ".background.tiff").is_file(), "Retina background is missing")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            for name, position in layout["icon_locations"].items():
                require(store[name]["Iloc"] == tuple(position),
                        f"Incorrect Finder position for {name}")
            icon_view = store["."]["icvp"]
            require(icon_view["iconSize"] == layout["icon_size"], "Incorrect Finder icon size")
            require(icon_view["backgroundType"] == 2, "Finder background is not an image")
            background = Alias.from_bytes(icon_view["backgroundImageAlias"])
            require(background.target.filename == ".background.tiff", "Incorrect background alias")
            window = store["."]["bwsp"]
            require(not window["ShowToolbar"] and not window["ShowSidebar"],
                    "Installer window must hide the toolbar and sidebar")
            require(window["WindowBounds"] ==
                    f"{{{{180, 120}}, {{{layout['width']}, {layout['height']}}}}}",
                    "Incorrect installer window dimensions")
        verify_app(mount / APP_NAME)
        # A copy out of the image must preserve the app signature, as Finder installation does.
        installed = work / "installed" / APP_NAME
        run("ditto", mount / APP_NAME, installed)
        verify_app(installed)
    finally:
        run("hdiutil", "detach", device)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=ROOT / "dist" / APP_NAME)
    parser.add_argument("output", nargs="?", type=Path,
                        default=ROOT / "dist/Android-File-Transfer-macOS-universal.dmg")
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    require(output.suffix == ".dmg", "Output path must end in .dmg")
    verify_app(app)
    layout = json.loads((ASSETS / "layout.json").read_text())
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".dmg-build-", dir=output.parent) as temporary:
        work = Path(temporary)
        image = work / output.name
        dmgbuild.build_dmg(str(image), VOLUME_NAME, settings={
            "format": "UDZO",
            "compression_level": 9,
            "filesystem": "HFS+",
            "files": [(str(app), APP_NAME)],
            "symlinks": {"Applications": "/Applications"},
            "icon": str(ROOT / "AppBundle/AppIcon.icns"),
            "background": str(ASSETS / "background.png"),
            "hide": [".background.tiff", ".VolumeIcon.icns"],
            "window_rect": ((180, 120), (layout["width"], layout["height"])),
            "icon_locations": layout["icon_locations"],
            "icon_size": layout["icon_size"],
            "text_size": 13,
            "default_view": "icon-view",
            "include_icon_view_settings": True,
            "include_list_view_settings": False,
            "show_status_bar": False,
            "show_tab_view": False,
            "show_toolbar": False,
            "show_pathbar": False,
            "show_sidebar": False,
        })
        verify_image(image, work, layout)
        image.replace(output)
    print(f"Built and verified {output}")


if __name__ == "__main__":
    main()
