#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIGURATION="Release" ./Scripts/build.sh

APP="$ROOT/build/Build/Products/Release/Don't Touch My Mac.app"
DMG_DIR="$ROOT/build/DMG_STAGING"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

OUTPUT="$ROOT/build/DontTouchMyMac.dmg"
rm -f "$OUTPUT"
hdiutil create -volname "Don't Touch My Mac" -srcfolder "$DMG_DIR" -ov -format UDZO "$OUTPUT"
rm -rf "$DMG_DIR"

printf '%s\n' "打包完成：$OUTPUT"
