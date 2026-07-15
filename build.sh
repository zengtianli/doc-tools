#!/bin/bash
# build.sh — build DocTools.app (Release) and optionally install it.
#
#   ./build.sh             build → ./dist/DocTools.app
#   ./build.sh --install   build + copy into /Applications (falls back to ~/Applications)
#
# The app is ad-hoc signed (no Apple Developer certificate required). If you
# downloaded a prebuilt zip instead of building locally, clear the quarantine
# flag once:  xattr -cr "/Applications/DocTools.app"
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP_NAME="DocTools"
VERSION="1.0.0"

# xcodebuild needs a full Xcode (not just Command Line Tools).
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "→ Building (Release)…"
xcodebuild -project DocTools.xcodeproj -scheme DocTools -configuration Release build | tail -3

BUILT="$(xcodebuild -project DocTools.xcodeproj -scheme DocTools -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')"
SRC_APP="$BUILT/DocTools.app"
[ -d "$SRC_APP" ] || { echo "❌ Build product not found: $SRC_APP"; exit 1; }

echo "→ Post-build (display name / icon / version / bundled backend / ad-hoc re-sign)…"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$SRC_APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon" "$SRC_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$SRC_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$SRC_APP/Contents/Info.plist"
cp "$DIR/icon/AppIcon.icns" "$SRC_APP/Contents/Resources/AppIcon.icns"

# Bundle the Python backend into the app (Contents/Resources/backend/).
if [ -d "$DIR/backend" ]; then
  rm -rf "$SRC_APP/Contents/Resources/backend"
  cp -R "$DIR/backend" "$SRC_APP/Contents/Resources/backend"
  rm -rf "$SRC_APP/Contents/Resources/backend/__pycache__"
else
  echo "⚠️  backend/ not found — building the GUI shell only (the app will report a backend error until backend/ exists)."
fi

codesign --force -s - "$SRC_APP"   # resources changed → re-sign (ad-hoc)

mkdir -p "$DIR/dist"
rm -rf "$DIR/dist/$APP_NAME.app"
cp -R "$SRC_APP" "$DIR/dist/$APP_NAME.app"
echo "✅ Built → $DIR/dist/$APP_NAME.app"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/$APP_NAME.app"
  if ! rm -rf "$DEST" 2>/dev/null || ! cp -R "$DIR/dist/$APP_NAME.app" "$DEST" 2>/dev/null; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"; cp -R "$DIR/dist/$APP_NAME.app" "$DEST"
  fi
  echo "✅ Installed → $DEST"
fi
