#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ $# != 1 || ! -d "$1/Contents" ]]; then
    printf 'Usage: bash release.sh path/to/App.app\n' >&2
    exit 1
fi
APP_PATH="$(cd "$1" && pwd)"
PLIST="$APP_PATH/Contents/Info.plist"
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
[[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9\ -]*$ && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$(basename "$APP_PATH")" == "$NAME.app" ]]
[[ "$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")" == arm64 ]]
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$ROOT/dist" "$ROOT/.build"
ASSET_NAME="${NAME// /-}"
ARCHIVE="$ROOT/dist/$ASSET_NAME-$VERSION-macOS-arm64.zip"
[[ ! -e "$ARCHIVE" ]] || { printf 'Archive already exists: %s\n' "$ARCHIVE" >&2; exit 1; }
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_PATH" "$ARCHIVE"
CHECK_DIR=$(mktemp -d "$ROOT/.build/release-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$CHECK_DIR"
/usr/bin/codesign --verify --deep --strict "$CHECK_DIR/$NAME.app"
/usr/bin/diff -qr "$APP_PATH" "$CHECK_DIR/$NAME.app"
(cd "$ROOT/dist" && /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf 'Verified archive: %s\n' "$ARCHIVE"
