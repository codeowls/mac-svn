#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP_DIR="$PWD/dist/Mac SVN.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/MacSVN" "$APP_DIR/Contents/MacOS/MacSVN"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacSVN</string>
    <key>CFBundleIdentifier</key><string>io.github.codeowls.mac-svn</string>
    <key>CFBundleName</key><string>Mac SVN</string>
    <key>CFBundleDisplayName</key><string>Mac SVN</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf '\n已生成：%s\n' "$APP_DIR"
