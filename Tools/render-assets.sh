#!/bin/zsh
# Regenerates the app icon (Resources/Assets.xcassets) and the README images (docs/).
set -euo pipefail
cd "${0:A:h}/.."

OUT=build/tools
ICONSET=Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$OUT" docs "$ICONSET"

echo "→ Drawing the icon…"
swiftc -parse-as-library -O Tools/IconRenderer.swift -o "$OUT/icon-renderer"
"$OUT/icon-renderer" "$OUT"
for size in 16 32 128 256 512; do
  sips -z $size $size "$OUT/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$OUT/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 256 256 "$OUT/icon_rounded.png" --out docs/icon.png >/dev/null

echo "→ Rendering widget previews…"
swiftc -parse-as-library -target arm64-apple-macos14.0 -swift-version 5 \
  Shared/*.swift Widget/WidgetViews.swift Tools/PreviewRenderer.swift -o "$OUT/preview-renderer"
"$OUT/preview-renderer" docs

echo "✓ Updated $ICONSET and docs/"
