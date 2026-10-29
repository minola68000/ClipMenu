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
# Stable Apple Development identity — ad-hoc re-sign breaks Accessibility TCC every install.
# Override with CLIPMENU_SIGN_IDENTITY; otherwise use the first Apple Development identity in the keychain.
IDENTITY="${CLIPMENU_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
if [ -n "$IDENTITY" ] && codesign -f --deep --options runtime -s "$IDENTITY" /Applications/ClipMenu.app; then
  echo "Signed with $IDENTITY"
else
  echo "WARNING: no Apple Development identity (or codesign failed); leaving Xcode signature" >&2
fi
open /Applications/ClipMenu.app
echo "Installed /Applications/ClipMenu.app"
echo "Enable ClipMenu in: Privacy & Security → Accessibility AND Input Monitoring"
