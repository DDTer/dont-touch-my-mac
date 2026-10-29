#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
if command -v xcodegen >/dev/null; then
  xcodegen generate --spec project.yml
fi
CONFIGURATION="${CONFIGURATION:-Release}"
xcodebuild -quiet -project DontTouchMyMac.xcodeproj -scheme DontTouchMyMac -configuration "$CONFIGURATION" -derivedDataPath "$ROOT/build" build
APP="$ROOT/build/Build/Products/$CONFIGURATION/Don't Touch My Mac.app"
"$APP/Contents/MacOS/Don't Touch My Mac" --self-test
codesign --verify --deep --strict "$APP"
printf '%s\n' "构建完成：$APP"
