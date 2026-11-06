#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SOURCE_DIR/.build"
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$SOURCE_DIR/Info.plist")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_DIR/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SOURCE_DIR/Info.plist")
ICON=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SOURCE_DIR/Info.plist")
APP_PATH="$SOURCE_DIR/dist/$NAME.app"
mkdir -p "$BUILD_DIR/module-cache" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
SDK_PATH="${MACOSX_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# shortcut: the 27.0 CLI SDK lacks the SwiftUI State macro plugin; prefer 26.5 until Apple fixes it.
COMPAT_SDK="$(xcode-select -p)/SDKs/MacOSX26.5.sdk"
if [[ -z "${MACOSX_SDK_PATH:-}" && -d "$COMPAT_SDK" ]]; then SDK_PATH="$COMPAT_SDK"; fi
SWIFT_ARGS=(-swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/module-cache" -target "arm64-apple-macosx$MIN_OS" -parse-as-library)
SOURCES=("$SOURCE_DIR/Core.swift" "$SOURCE_DIR/AppMetadata.swift" "$SOURCE_DIR/LocalTool.swift" "$SOURCE_DIR/Platform.swift")
xcrun swiftc "${SWIFT_ARGS[@]}" "${SOURCES[@]}" "$SOURCE_DIR/Tests.swift" -o "$BUILD_DIR/profile-tests"
"$BUILD_DIR/profile-tests"
xcrun swiftc "${SWIFT_ARGS[@]}" -O "${SOURCES[@]}" "$SOURCE_DIR/App.swift" -o "$APP_PATH/Contents/MacOS/$EXECUTABLE"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE_DIR/assets/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$SOURCE_DIR/assets/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/$ICON"
cp "$SOURCE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
