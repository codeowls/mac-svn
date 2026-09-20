#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS-2}"
if [[ ! "$SWIFT_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'SWIFT_BUILD_JOBS must be a positive integer: %s\n' "$SWIFT_BUILD_JOBS" >&2
    exit 1
fi
APP_VERSION="$(cat VERSION)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid VERSION: %s\n' "$APP_VERSION" >&2
    exit 1
fi
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Limit both SwiftPM scheduling and the release compiler's internal threads.
# This keeps local builds responsive; callers can explicitly raise the limit.
BUILD_ARGS=(-c release --sdk "$MACOS_SDK_PATH" --jobs "$SWIFT_BUILD_JOBS"
    -Xswiftc -num-threads -Xswiftc "$SWIFT_BUILD_JOBS")
case "${1:-}" in
    "") ARCHITECTURES=("$(uname -m)") ;;
    --universal) ARCHITECTURES=(arm64 x86_64) ;;
    *) printf 'Usage: bash scripts/build-app.sh [--universal]\n' >&2; exit 1 ;;
esac
# Keep the linked SDK distinct from the macOS 14 deployment target in Package.swift.
# SwiftPM with Command Line Tools can otherwise mark both as 14 and retain legacy UI.
# Build each slice separately: Xcode 16's multi-architecture SwiftPM backend
# forwards linker flags to clang differently from its single-architecture backend.
BINARIES=()
printf 'Building with up to %s parallel jobs and compiler threads.\n' "$SWIFT_BUILD_JOBS"
for architecture in "${ARCHITECTURES[@]}"; do
    swift build "${BUILD_ARGS[@]}" --arch "$architecture" \
        -Xlinker -platform_version -Xlinker macos \
        -Xlinker 14.0 -Xlinker "$MACOS_SDK_VERSION"
    BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --arch "$architecture" --show-bin-path)"
    SLICE_DIR="$PWD/.build/release-slices/$architecture"
    mkdir -p "$SLICE_DIR"
    cp "$BIN_DIR/MacSVN" "$SLICE_DIR/MacSVN"
    BINARIES+=("$SLICE_DIR/MacSVN")
done
bash scripts/build-icon.sh

APP_DIR="$PWD/dist/Mac SVN.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/MacSVN"
cp "$PWD/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PWD/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
# SwiftPM's generated accessor looks for localized resources in the app's Resources directory.
cp -R "$BIN_DIR/MacSVN_SVNCore.bundle" "$APP_DIR/Contents/Resources/"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacSVN</string>
    <key>CFBundleIdentifier</key><string>io.github.codeowls.mac-svn</string>
    <key>CFBundleName</key><string>Mac SVN</string>
    <key>CFBundleDisplayName</key><string>Mac SVN</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>io.github.codeowls.mac-svn.finder</string>
        <key>CFBundleURLSchemes</key><array><string>macsvn</string></array>
        <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict></array>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
bash scripts/build-finder-extension.sh "${ARCHITECTURES[@]}"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Refresh only this app's Launch Services registration after an in-place rebuild.
touch "$APP_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"
printf '\n已生成：%s\n' "$APP_DIR"
