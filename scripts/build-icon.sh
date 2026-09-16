#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

ICON_SOURCE="$PWD/assets/AppIcon-v1.png"
ICONSET_DIR="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Preserve the artwork's alpha while exporting the standard macOS 1x and 2x sizes.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" > /dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil --convert icns "$ICONSET_DIR" --output "$PWD/assets/AppIcon.icns"
printf '已生成：%s\n' "$PWD/assets/AppIcon.icns"
