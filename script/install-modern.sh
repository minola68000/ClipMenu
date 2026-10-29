#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/script/build-modern.sh"
APP_SRC="$ROOT/build/Release/ClipMenuNeo.app"
pkill -f 'ClipMenuNeo.app/Contents/MacOS/ClipMenuNeo' || true
sleep 1
# Replace in place; do not leave backup copies in /Applications (they show up in Launchpad / Spotlight).
rm -rf /Applications/ClipMenuNeo.app
cp -R "$APP_SRC" /Applications/ClipMenuNeo.app
xattr -dr com.apple.quarantine /Applications/ClipMenuNeo.app 2>/dev/null || true
# Stable Apple Development identity — ad-hoc re-sign breaks Accessibility TCC every install.
# Override with CLIPMENU_SIGN_IDENTITY; otherwise use the first Apple Development identity in the keychain.
IDENTITY="${CLIPMENU_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
if [ -n "$IDENTITY" ] && codesign -f --deep --options runtime -s "$IDENTITY" /Applications/ClipMenuNeo.app; then
  echo "Signed with $IDENTITY"
else
  echo "WARNING: no Apple Development identity (or codesign failed); leaving Xcode signature" >&2
fi
open /Applications/ClipMenuNeo.app
echo "Installed /Applications/ClipMenuNeo.app"
echo "Enable ClipMenu in: Privacy & Security → Accessibility AND Input Monitoring"
