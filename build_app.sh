#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$(mktemp -d /tmp/view-media-info-build.XXXXXX)"
APP_DIR="$STAGING_DIR/View Media Info.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
ARCHIVE_PATH="$BUILD_DIR/View Media Info.app.zip"

trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

xcrun swiftc \
    -O \
    -parse-as-library \
    -D STANDALONE_MEDIA_INFO \
    -module-cache-path "$MODULE_CACHE_DIR" \
    "$PROJECT_DIR/Sources/ViewMediaInfo/main.swift" \
    -o "$MACOS_DIR/ViewMediaInfo" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -framework QuickLookUI \
    -framework QuickLookThumbnailing \
    -framework ImageIO \
    -framework AVFoundation \
    -framework CoreLocation \
    -framework MapKit \
    -lsqlite3

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$PROJECT_DIR/Resources/en.lproj" "$RESOURCES_DIR/en.lproj"
cp -R "$PROJECT_DIR/Resources/zh-Hans.lproj" "$RESOURCES_DIR/zh-Hans.lproj"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"

echo "$ARCHIVE_PATH"
