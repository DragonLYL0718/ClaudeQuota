#!/bin/zsh
# Render synthetic layout coverage, without reading the user's accounts or installing the app.
set -euo pipefail
cd "${0:A:h}/.."
OUT="${1:-build/ui-previews}"
mkdir -p "$OUT" build/tools
VIEWS=(Widget/*.swift(N))
VIEWS=(${VIEWS:#*/QuotaWidget.swift})
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path build/tools/module-cache \
  Shared/*.swift $VIEWS Tools/UIPreviewRenderer.swift -o build/tools/ui-preview-renderer
build/tools/ui-preview-renderer "$OUT"
