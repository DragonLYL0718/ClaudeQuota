#!/bin/zsh
# Build Claude Quota and install it into /Applications.
set -euo pipefail
cd "${0:A:h}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ Installing XcodeGen (Homebrew)…"
  brew install xcodegen
fi

echo "→ Generating the Xcode project…"
xcodegen generate --quiet

# A fresh build number every time, so WidgetKit treats each install as a new version.
BUILD_NUMBER=$(date +%Y%m%d%H%M)

echo "→ Building ($BUILD_NUMBER)…"
xcodebuild -project ClaudeQuota.xcodeproj -scheme ClaudeQuota -configuration Release \
  -derivedDataPath build -quiet CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

APP="build/Build/Products/Release/ClaudeQuota.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

echo "→ Installing to /Applications…"
osascript -e 'tell application id "com.rayleigh.ClaudeQuota" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/ClaudeQuota.app
ditto "$APP" /Applications/ClaudeQuota.app

# Keep only the installed copy registered, and stop the running widget process:
# otherwise the desktop keeps showing the previous version's code.
"$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f /Applications/ClaudeQuota.app >/dev/null 2>&1 || true
pkill -x ClaudeQuotaWidget >/dev/null 2>&1 || true

open /Applications/ClaudeQuota.app
echo "✓ Installed /Applications/ClaudeQuota.app"
