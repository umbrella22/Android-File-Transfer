# Interface screenshots

The app screenshots render the repository's `ContentView` and `SettingsView` with AppKit window frames on macOS. A temporary documentation app selects the public repository folder as the local browsing location and switches the existing localization between English and Simplified Chinese.

| Image | View |
| --- | --- |
| `main-en.png` | English file browser; no Android device connected. |
| `main-zh-CN.png` | Simplified Chinese file browser; no Android device connected. |
| `settings-en.png` | English settings. |
| `settings-zh-CN.png` | Simplified Chinese settings. |
| `dmg-installer.png` | Actual Finder window of the packaged DMG, with the app and Applications shortcut. |

The device pane uses its disconnected state. No device listings, installation controls, or transfer progress are fabricated. Screenshot capture does not change the production app's startup behavior.

The installer screenshot uses the background and layout from `AppBundle/DMG`. Finder's hidden-file, path-bar, and status-bar visibility were temporarily disabled for capture, then restored. Release packaging itself does not change Finder preferences.
