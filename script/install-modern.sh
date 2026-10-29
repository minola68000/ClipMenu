#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/script/build-modern.sh"
APP_SRC="$ROOT/build/Release/ClipMenu.app"
pkill -f 'ClipMenu.app/Contents/MacOS/ClipMenu' || true
sleep 1
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -d /Applications/ClipMenu.app ]; then
  mv /Applications/ClipMenu.app "/Applications/ClipMenu.app.pre-modern-$STAMP"
fi
cp -R "$APP_SRC" /Applications/ClipMenu.app
xattr -dr com.apple.quarantine /Applications/ClipMenu.app 2>/dev/null || true
codesign --force --deep -s - /Applications/ClipMenu.app
open /Applications/ClipMenu.app
echo "Installed /Applications/ClipMenu.app"
