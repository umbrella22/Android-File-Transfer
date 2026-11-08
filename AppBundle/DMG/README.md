# Drag-to-install artwork

The installer uses a 768 × 512 point canvas with a light blue background, the app at the left, an Applications shortcut at the right, and English and Simplified Chinese instructions.

- `artwork.png`: generated decorative texture, 1536 × 1024 pixels.
- `background.png`: finished background at 1× resolution.
- `background@2x.png`: finished background at 2× resolution, with a logical size of 768 × 512 points.
- `layout.json`: canvas dimensions, icon size, and Finder icon positions shared by the renderer and packager.

The texture was generated using the `codex-image-gen-bridge` skill with provider `custom`, endpoint `https://ai.orzi.me`, wire API `responses`, and model `gpt-image-2.5-flare`. Typography, icon guides, and the arrow are composed locally with AppKit, using the existing application's blue palette.

To regenerate the finished backgrounds after editing the texture or typography, run from the repository root on macOS:

```sh
swift Scripts/render-dmg-background.swift
```

The backgrounds are committed assets. Release packaging combines their two resolutions into a TIFF inside the disk image. It does not require an image-generation service or API credentials.
