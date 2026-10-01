# View Media Info

View Media Info is a native macOS app for quickly reading the useful details
inside a photo, video, audio file, or Live Photo. Open a file from Finder or
choose one in the app to see its format, dimensions, date, camera or recording
details, location, and other available metadata — without modifying the file.

[简体中文说明](README.zh-CN.md) · [Project website](https://jingyuan-zheng.github.io) · [Source](https://github.com/Jingyuan-Zheng/View-Media-Info)

![A Live Photo in the compact view](docs/screenshots/live-photo-summary.png)

## Install and get started

View Media Info needs macOS 26 or later.

### Install the app

1. Download `Media Information-<version>.dmg` from the project’s Releases page.
2. Open the DMG and drag **View Media Info** to **Applications**.
3. Open **View Media Info**. Choose **File → Open Media…** or press `⌘O`, then select a photo, video, or audio file.

The app only reads information. It never edits, renames, uploads, or writes
metadata back to your media.

### Use it from Finder

The optional Finder Quick Action lets you inspect a selected file without
opening the app first.

1. Download and unzip `View Media Data Quick Action-<version>.zip`.
2. Double-click **View Media Data.workflow**, then select **Install**.
3. In Finder, Control-click a media file and choose **Quick Actions → View Media Data**.

The Quick Action includes its own copy of the app and installs in
`~/Library/Services`; it works independently of the copy in Applications.

### Read, preview, and copy information

- The first screen shows the essentials. Choose **Details** for the complete metadata view.
- Choose **Copy Results** to copy the information currently shown.
- Press Space to open or close macOS Quick Look. Double-click an image or Live Photo preview to open it there.
- Video and audio artwork include a play button when a preview is available.
- Live Photos show the HEIC photo’s dimensions while their companion movie plays in the correct display orientation.

### Adjust settings

Choose **Media Information → Settings…** to select Chinese or English. The
language change takes effect the next time you open the app. Dates and times
otherwise follow your Mac’s regional settings.

If macOS blocks the first launch, Control-click the app or workflow, choose
**Open**, then confirm the prompt. Releases are ad-hoc signed and are not
notarized.

## Examples

### Photo and Live Photo

![Photo metadata in the compact view](docs/screenshots/photo-summary.png)

![HEIC file details](docs/screenshots/heic-details.png)

### Video

![Video metadata in the compact view](docs/screenshots/video-summary.png)

### Audio

![Audio metadata in the compact view](docs/screenshots/audio-summary.png)

## Features in detail

### A compact view first, complete metadata on demand

Every file opens in a focused summary designed for a quick answer: a visual
preview, its most useful dimensions or duration, and the most relevant fields
for that type of media. Choose **Details** to expand into grouped file,
technical, camera, recording, date, and location information. **Copy Results**
copies the visible result so it can be pasted into a message, note, or issue.

### Photos

- Displays the file format, extension, MIME/container details, file size,
  stored pixel width and height, megapixels, bit depth, colour information,
  orientation, and available XMP/IPTC data.
- Shows a scaled visual diagram of the image dimensions alongside its
  thumbnail, so landscape, portrait, and high-resolution images are easy to
  identify at a glance.
- Reads camera and lens metadata when present: manufacturer, model, lens name,
  focal length and range, aperture, shutter speed, ISO, exposure settings, and
  capture date.
- Shows GPS coordinates and resolves them to a place name when macOS can do
  so. If a location lookup is unavailable, the original coordinates remain
  available in Details.

### Live Photos and motion photos

- Detects Apple Live Photos by matching the HEIC and companion movie
  `ContentIdentifier` in the same folder.
- Recognises common Android motion-photo metadata and embedded video payloads.
- Loops the motion component in the preview while reporting dimensions and
  megapixels from the still photo itself.
- Respects the companion video’s display transform, so rotated portrait motion
  is shown in the correct orientation without being cropped.

### Videos

- Presents a video thumbnail with Quick Look playback and a dimension diagram
  showing stored width, height, megapixels, and frame rate.
- Reads duration, codec, bitrate, container format, creation/capture date,
  device, and location when those fields are included in the file.
- Reports available audio-stream properties such as codec, bitrate, sample
  rate, and channel count alongside the video information.

### Audio

- Shows embedded album artwork, or a native placeholder when there is none.
- Reads title, artist, album, album artist, composer, track and disc numbers,
  year, genre, and comments when available.
- Displays duration, file size, format, codec, bitrate, sample rate, bit
  depth, and channel layout.
- Uses a preview play button when macOS can play the selected file.

### Native macOS behaviour and privacy

- Uses Quick Look for previews and the standard macOS About panel for app and
  version information.
- Supports Chinese and English; the first launch follows macOS, while a choice
  in Settings is applied at the next launch.
- Reads media only. It never changes a file, persists a metadata database, or
  uploads media. Reverse geocoding uses Apple system services only when a
  location name is requested.

The file picker accepts images, movies, and audio files. macOS and the
installed metadata tools determine the exact formats available; common HEIC,
JPEG, PNG, MOV, MP4, MP3, M4A, FLAC, WAV, and AIFF files are supported.

## Requirements and metadata tools

- **ExifTool** is required for image and audio metadata. The app searches
  `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`.
- **ffprobe** is optional, but adds richer video and audio stream information.
  The app searches `/opt/homebrew/bin` and `/usr/local/bin`.

Install both with Homebrew if you use it:

```sh
brew install exiftool ffmpeg
```

Location names are resolved with Apple system services only when needed. If a
lookup is unavailable, the original coordinates are shown instead.

## About

Choose **Media Information → About Media Information** for the native macOS
About panel, which shows the app icon and version plus links to the author,
website, source repository, and MIT license.

## Build and release

Build the standalone app bundle without Xcode:

```sh
./build_app.sh
```

The script compiles with `STANDALONE_MEDIA_INFO`, ad-hoc signs and verifies the
bundle, then writes `build/View Media Info.app.zip`.

To create both release assets, keep [Dmg Maker](../Dmg%20Maker) beside this
repository and run:

```sh
./scripts/package_release.sh
```

It creates a Dmg Maker DMG for the standalone app and a ZIP containing the
installable Finder Quick Action in `release/`.

## Project layout

- `Sources/ViewMediaInfo/main.swift` — application source.
- `Resources/` — app icon and localized menu resources.
- `Info.plist` — bundle metadata.
- `build_app.sh` — standalone build script.
- `Workflow/` — Finder Quick Action template; packaging adds the compiled app.
- `scripts/package_release.sh` — release packager.

Metadata is read through ExifTool, ffprobe, ImageIO, AVFoundation, Quick Look,
Core Location, and MapKit. Parsing is read-only; a targeted legacy-encoding
recovery path is used only for malformed metadata text.

## License

Released under the [MIT License](LICENSE).
