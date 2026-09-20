#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 ]]; then
    printf 'Usage: bash scripts/build-finder-extension.sh arm64 [x86_64]\n' >&2
    exit 1
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
EXTENSION_DIR="$PWD/dist/Mac SVN.app/Contents/PlugIns/MacSVNFinder.appex"
mkdir -p "$EXTENSION_DIR/Contents/MacOS" "$PWD/.build/finder-slices"
BINARIES=()
for architecture in "$@"; do
    case "$architecture" in arm64|x86_64) ;; *) exit 1 ;; esac
    BINARY="$PWD/.build/finder-slices/$architecture"
    xcrun swiftc -swift-version 6 -O -parse-as-library -application-extension \
        -sdk "$SDK_PATH" -target "$architecture-apple-macosx14.0" \
        -module-name MacSVNFinder -framework AppKit -framework FinderSync \
        -Xlinker -e -Xlinker _NSExtensionMain \
        Sources/SVNCore/FinderConfiguration.swift Extensions/FinderSync/FinderSync.swift -o "$BINARY"
    BINARIES+=("$BINARY")
done
lipo -create "${BINARIES[@]}" -output "$EXTENSION_DIR/Contents/MacOS/MacSVNFinder"
/usr/bin/python3 - "$EXTENSION_DIR" "$(cat VERSION)" <<'PY'
from pathlib import Path
import plistlib
import sys
extension, version = sys.argv[1:]
info = {
    'CFBundleIdentifier': 'io.github.codeowls.mac-svn.finder',
    'CFBundleExecutable': 'MacSVNFinder',
    'CFBundleName': 'Mac SVN Finder',
    'CFBundleDisplayName': 'Mac SVN',
    'CFBundlePackageType': 'XPC!',
    'CFBundleVersion': version,
    'CFBundleShortVersionString': version,
    'CFBundleDevelopmentRegion': 'zh-Hans',
    'CFBundleLocalizations': ['zh-Hans', 'en'],
    'LSMinimumSystemVersion': '14.0',
    'NSExtension': {
        'NSExtensionPointIdentifier': 'com.apple.FinderSync',
        'NSExtensionPrincipalClass': 'MacSVNFinderSync',
        'NSExtensionAttributes': {},
    },
}
with (Path(extension) / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(info, output)
PY
codesign --force --sign - --entitlements Extensions/FinderSync/FinderSync.entitlements "$EXTENSION_DIR"
codesign --verify --strict "$EXTENSION_DIR"
