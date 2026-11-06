# Android File Transfer (Swift)

A native macOS MTP client for browsing and transferring files between a Mac and Android devices over USB — written entirely in Swift with SwiftUI and Apple's IOUSBHost framework.

**English** · [简体中文](README.zh-CN.md)

## Overview

Android File Transfer (Swift) talks to Android devices directly through Apple's `IOUSBHost` framework — no Go runtime, no libusb, no `kalam.dylib`, and no FFI/JSON bridge. The MTP protocol stack and the SwiftUI interface are both implemented in this repository.

> This is an independent project and is not affiliated with Google's Android File Transfer app.

## Features

- Native SwiftUI interface with a sidebar and dual panes (local / device)
- Browse internal storage and SD cards, including category storage
- Upload and download files and nested folders with recursive progress
- Persistent multi-job transfer queue that survives relaunch
- Pause, resume, cancel, retry, and per-job progress
- Conflict handling: Replace, Keep Both, or Cancel
- Batch delete, including recursive folder deletion
- Drag files or folders from Finder onto the device, and drag device files back to Finder
- Quick Look for local and device files
- IOKit hotplug notifications with automatic reconnect
- English and Simplified Chinese, with live language switching
- First-run onboarding, native Settings, and a File Access permission guide
- Full Disk Access helper with direct links to the relevant privacy panes

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 26 or later)
- An Android device that supports MTP (select **File Transfer / MTP** after connecting)

## Quick start

```sh
git clone https://github.com/umbrella22/Android-File-Transfer.git
cd Android-File-Transfer

swift build
swift test          # 18 tests
./Scripts/build-app.sh debug --install
open "$HOME/Applications/Android File Transfer.app"
```

The app must run from the internal disk. Running the bundle directly from a removable or project volume can trigger macOS privacy prompts; `--install` copies it to `~/Applications` first.

## Project structure

```
Sources/AndroidFileTransferKit/    MTP/PTP protocol stack and USB transport
Sources/AndroidFileTransferApp/    SwiftUI macOS app
AppBundle/                         Info.plist, app icon, en/zh-Hans metadata
Scripts/build-app.sh               Build, copy resources, ad-hoc sign, install
Tests/AndroidFileTransferKitTests/ Codec, dataset, and mock-session tests
```

## Architecture

`AndroidFileTransferKit` is split into three layers:

- **PTP** — container codec, MTP UTF-16 strings, and dataset types.
- **USB** — the `USBTransport` byte-pipe abstraction; `IOUSBHostTransport` is the production implementation.
- **MTP** — `MTPDeviceSession`, an actor that serializes every transaction behind a FIFO bus gate.

The app depends only on the transport abstraction, so another USB backend can be added without touching the MTP or UI layers.

## Status

- 18 unit tests pass (PTP codec, datasets, and mock MTP session).
- Hardware-verified on a nubia Z70 Ultra (MTP 6/1/1), including 4.1 GB upload/download round-trips with matching SHA-256 values.
- Still pending: physical unplug during a transfer, sleep/wake, and a wider vendor matrix.

## Known limitations

- Pause/resume restarts the current job from the beginning; there is no byte-level resume.
- Drag-out supports a single file or a single folder, not multi-selection.
- Uploading a symbolic link itself is not supported.
- Only English and Simplified Chinese are translated.
- Builds are ad-hoc signed; notarization and App Store packaging are not set up yet.
