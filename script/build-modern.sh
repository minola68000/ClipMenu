#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS="${CLIPMENU_ARCHS:-arm64 x86_64}"

xcodebuild \
  -project ClipMenu.xcodeproj \
  -target ClipMenu \
  -configuration Release \
  SDKROOT=macosx \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  LD_RUNPATH_SEARCH_PATHS="@executable_path/../Frameworks" \
  FRAMEWORK_SEARCH_PATHS="$ROOT/Frameworks" \
  HEADER_SEARCH_PATHS="$ROOT/Source $ROOT/Source/NaoAdditions $ROOT/Source/Compatibility" \
  OTHER_LDFLAGS="-ObjC" \
  build

APP="$ROOT/build/Release/ClipMenu.app"
mkdir -p "$APP/Contents/Frameworks"
for fw in ShortcutRecorder Sparkle BWToolkitFramework; do
  rm -rf "$APP/Contents/Frameworks/$fw.framework"
  cp -R "$ROOT/Frameworks/$fw.framework" "$APP/Contents/Frameworks/"
done

mkdir -p "$APP/Contents/Resources/English.lproj" "$APP/Contents/Resources/Japanese.lproj"
cp -f "$ROOT/English.lproj/MainMenu.nib" "$APP/Contents/Resources/English.lproj/" 2>/dev/null || true
cp -f "$ROOT/English.lproj/Preferences.nib" "$APP/Contents/Resources/English.lproj/" 2>/dev/null || true
cp -f "$ROOT/English.lproj/SnippetEditor.nib" "$APP/Contents/Resources/English.lproj/" 2>/dev/null || true
cp -f "$ROOT/Japanese.lproj/Preferences.nib" "$APP/Contents/Resources/Japanese.lproj/" 2>/dev/null || true
cp -f "$ROOT/Japanese.lproj/SnippetEditor.nib" "$APP/Contents/Resources/Japanese.lproj/" 2>/dev/null || true

codesign --force --deep -s - "$APP"
echo "Built: $APP"
file "$APP/Contents/MacOS/ClipMenu"
lipo -info "$APP/Contents/MacOS/ClipMenu"
defaults read "$APP/Contents/Info" CFBundleShortVersionString
