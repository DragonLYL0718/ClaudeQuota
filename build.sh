#!/bin/zsh
# Build "Claude 额度" and install it into /Applications.
set -euo pipefail
cd "${0:A:h}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ Installing XcodeGen (Homebrew)…"
  brew install xcodegen
fi

echo "→ Generating the Xcode project…"
xcodegen generate --quiet

echo "→ Building…"
xcodebuild -project ClaudeQuota.xcodeproj -scheme ClaudeQuota -configuration Release \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Release/ClaudeQuota.app"
echo "→ Installing to /Applications…"
osascript -e 'quit app "ClaudeQuota"' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/ClaudeQuota.app
ditto "$APP" /Applications/ClaudeQuota.app
open /Applications/ClaudeQuota.app
echo "✓ Installed /Applications/ClaudeQuota.app"
