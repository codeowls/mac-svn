#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bash scripts/build-icon.sh

APP_DIR="$PWD/dist/Mac SVN.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/MacSVN" "$APP_DIR/Contents/MacOS/MacSVN"
cp "$PWD/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
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
    <array><string>zh-Hans</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP_DIR"
# Refresh only this app's Launch Services registration after an in-place rebuild.
touch "$APP_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"
printf '\n已生成：%s\n' "$APP_DIR"
