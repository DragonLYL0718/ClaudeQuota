#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

./Tests/install-app-tests.sh
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --quiet
xcodebuild -project QuotaRings.xcodeproj -scheme QuotaRingsTests \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build -quiet test
