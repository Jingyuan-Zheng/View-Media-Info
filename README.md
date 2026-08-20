# View Media Info

A native macOS utility for reading the useful information inside your images,
videos, audio files, and motion photos. It is designed to be launched either
from Finder/Shortcuts with a file or on its own, then opened with **File → Open
Media…** (`⌘O`).

[简体中文说明](README.zh-CN.md)

## What it does

- Shows the essentials first: format, file size, real dimensions, camera or
  recording device, shooting date, location, and key photo/video/audio
  settings when present.
- Lets you expand to a complete, readable metadata view when you need more.
- Opens macOS Quick Look with Space. Videos and audio artwork also have a play
  button; images and motion photos open with a double-click on the preview.
- Recognises Apple Live Photos by their matching `ContentIdentifier` and plays
  the companion movie in a loop. It also recognises common Android motion-photo
  metadata and embedded video payloads.
- Displays music artwork, track/album/artist information, duration, encoding,
  bitrate, sample rate, and channels. Files without artwork use a native symbol
  placeholder.
- Uses your Mac's date/time formatting and can use Chinese or English. The
  initial language follows macOS; a choice made in Settings applies at the next
  launch.

## Your files stay local

View Media Info reads metadata only. It does not edit, rename, upload, or save
metadata back to your media files. Location names are resolved with Apple system
services when available; if a lookup cannot be completed, the original
coordinates are shown instead.

## Requirements

- macOS 26 or later.
- [ExifTool](https://exiftool.org/) must be available at one of the common
  locations (`/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`) to read image
  and audio metadata.
- `ffprobe` is optional but recommended for richer video and audio stream data.
  The app looks for it in `/opt/homebrew/bin` and `/usr/local/bin`.

The built-in file picker accepts only images, movies, and audio files. The exact
formats available depend on macOS and the installed metadata tools; common
formats such as HEIC, JPEG, PNG, MOV, MP4, MP3, M4A, FLAC, WAV, and AIFF are
supported by the parser.

## Use it

1. Build or obtain the app, then open it normally or pass it a media-file path.
2. If it starts without a file, choose **File → Open Media…** or press `⌘O`.
3. Read the compact view, select **Details** for the full view, and use
   **Copy Results** to copy the currently displayed information.
4. Press Space to show or hide Quick Look for an image, video, audio file, or
   motion photo.

## Build from source

This repository builds a standalone app bundle without Xcode:

```sh
./build_app.sh
```

The script compiles with `STANDALONE_MEDIA_INFO`, creates an ad-hoc signed app,
verifies it, and writes the portable archive here:

```text
build/View Media Info.app.zip
```

## For developers

### Project layout

- `Sources/ViewMediaInfo/main.swift` — application source.
- `Resources/` — app icon and localized menu resources.
- `Info.plist` — bundle metadata.
- `build_app.sh` — reproducible standalone build script.

The app is deliberately standalone. It is a recoverable copy of a helper used
by a separate workflow, not a linked module; keep changes in this repository
self-contained.

### Metadata pipeline

- ExifTool supplies image, audio, XMP, camera, GPS, embedded artwork, and Live
  Photo identifiers.
- `ffprobe`, when available, supplies video/audio stream details such as codec,
  frame rate, bitrate, sample rate, and channel layout.
- Core Location and MapKit reverse-geocode coordinates without storing resolved
  places in a database.
- Quick Look and AVFoundation provide previews, thumbnails, and looping motion
  playback.

All parsing is read-only. Text supplied by devices or media software has a
targeted legacy-encoding recovery path for malformed metadata; normal decoded
text is left unchanged.

### Contributing locally

Run `./build_app.sh` after changes. The generated `build/` directory is ignored
by Git. Keep changes focused, preserve the bilingual interface, and do not add
media fixtures containing private data.

## License

Released under the [MIT License](LICENSE).
