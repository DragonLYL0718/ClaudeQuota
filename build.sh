#!/bin/zsh
# Build Quota Rings, optionally installing it into /Applications.
set -euo pipefail
cd "${0:A:h}"

INSTALL_APP=1
for argument in "$@"; do
  case "$argument" in
    --build-only|--no-install) INSTALL_APP=0 ;;
    -h|--help)
      echo "Usage: ./build.sh [--build-only|--no-install]"
      exit 0
      ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ Installing XcodeGen (Homebrew)…"
  brew install xcodegen
fi

echo "→ Generating the Xcode project…"
xcodegen generate --quiet

# A fresh build number every time, so WidgetKit treats each install as a new version.
BUILD_NUMBER=$(date +%Y%m%d%H%M%S)

echo "→ Building ($BUILD_NUMBER)…"
xcodebuild -project QuotaRings.xcodeproj -scheme QuotaRings -configuration Release \
  -derivedDataPath build -quiet CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

APP="build/Build/Products/Release/QuotaRings.app"
if (( ! INSTALL_APP )); then
  echo "✓ Built $PWD/$APP"
  exit 0
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
source Tools/install-app.sh

# Called only after the replacement has been copied and validated.
prepare_replacement() {
  osascript -e 'tell application id "com.rayleigh.ClaudeQuota" to quit' >/dev/null 2>&1 || true
  sleep 1
}

echo "→ Installing to /Applications…"
install_app "$APP" /Applications/QuotaRings.app

# The app was called ClaudeQuota.app before it was renamed; it has the same bundle identifier.
# Retire old copies only after the replacement has been installed successfully.
for OLD in /Applications/ClaudeQuota.app build/Build/Products/Release/ClaudeQuota.app \
           build/Build/Products/Release/ClaudeQuotaWidget.appex; do
  if [[ -e "$OLD" ]]; then
    "$LSREGISTER" -u "$OLD" >/dev/null 2>&1 || true
    rm -rf "$OLD"
  fi
done
# Keep only the installed copy registered, and stop the running widget process:
# otherwise the desktop keeps showing the previous version's code.
"$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f /Applications/QuotaRings.app >/dev/null 2>&1 || true
pkill -x QuotaRingsWidget >/dev/null 2>&1 || true
pkill -x ClaudeQuotaWidget >/dev/null 2>&1 || true

open /Applications/QuotaRings.app
echo "✓ Installed /Applications/QuotaRings.app"
