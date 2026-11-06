#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SOURCE_DIR/.build"
APP_PATH="$SOURCE_DIR/dist/Loftlane.app"
mkdir -p "$BUILD_DIR/module-cache" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
SDK_PATH="${MACOSX_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# shortcut: the 27.0 CLI SDK lacks the SwiftUI State macro plugin; prefer 26.5 until Apple fixes it.
COMPAT_SDK="$(xcode-select -p)/SDKs/MacOSX26.5.sdk"
if [[ -z "${MACOSX_SDK_PATH:-}" && -d "$COMPAT_SDK" ]]; then SDK_PATH="$COMPAT_SDK"; fi
SWIFT_ARGS=(-swift-version 5 -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/module-cache" -target arm64-apple-macosx15.0 -parse-as-library)
xcrun swiftc "${SWIFT_ARGS[@]}" "$SOURCE_DIR/Core.swift" "$SOURCE_DIR/Tests.swift" -o "$BUILD_DIR/profile-tests"
"$BUILD_DIR/profile-tests"
xcrun swiftc "${SWIFT_ARGS[@]}" -O "$SOURCE_DIR/Core.swift" "$SOURCE_DIR/Platform.swift" "$SOURCE_DIR/App.swift" -o "$APP_PATH/Contents/MacOS/Loftlane"
ICONSET="$BUILD_DIR/Loftlane.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE_DIR/assets/Loftlane.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$SOURCE_DIR/assets/Loftlane.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/Loftlane.icns"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.polrai.claudeprofiles</string>
<key>CFBundleName</key><string>Loftlane</string>
<key>CFBundleDisplayName</key><string>Loftlane</string>
<key>CFBundleExecutable</key><string>Loftlane</string>
<key>CFBundleIconFile</key><string>Loftlane.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
