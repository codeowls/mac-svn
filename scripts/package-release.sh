#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
APP_VERSION="$(cat VERSION)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid VERSION: %s\n' "$APP_VERSION" >&2
    exit 1
fi
RELEASE_DIR="$PWD/dist/releases/$APP_VERSION"
if [[ -e "$RELEASE_DIR" ]]; then
    printf 'Release output already exists; refusing to overwrite: %s\n' "$RELEASE_DIR" >&2
    exit 1
fi

bash scripts/build-app.sh --universal
APP_DIR="$PWD/dist/Mac SVN.app"
codesign --verify --deep --strict "$APP_DIR"
for architecture in arm64 x86_64; do
    lipo "$APP_DIR/Contents/MacOS/MacSVN" -verify_arch "$architecture"
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" = "$APP_VERSION"

# Stage only distributable files; never include working copies or local settings.
STAGE_DIR="$(mktemp -d "$PWD/.build/release-stage.XXXXXX")"
ditto "$APP_DIR" "$STAGE_DIR/Mac SVN.app"
cp LICENSE "$STAGE_DIR/LICENSE"
cp docs/INSTALL.txt "$STAGE_DIR/INSTALL.txt"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$RELEASE_DIR"
ASSET_NAME="Mac-SVN-$APP_VERSION-universal"
hdiutil create -volname "Mac SVN $APP_VERSION" -srcfolder "$STAGE_DIR" \
    -format UDZO "$RELEASE_DIR/$ASSET_NAME.dmg"
hdiutil verify "$RELEASE_DIR/$ASSET_NAME.dmg"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "$ASSET_NAME.dmg" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
printf '\nRelease assets: %s\n' "$RELEASE_DIR"
