#!/usr/bin/env bash
# lifecycle: the command words of the app executable (status, settings, config …, update check), end to end
# and off screen — tests/test_lifecycle_cli.py.
#
# Compiles Sources/*.swift into a temporary .app with a test bundle identifier whose Resources symlink to the
# built bundle (bundled Python runtime) and the repo backend, then drives that executable as real processes:
# as the command, and a second time as the running app (activation policy prohibited, nothing ordered in).
# build/DocKit.app is read, never modified or rebuilt. Preferences live in a throwaway named domain that is
# removed afterwards; support and "cloud" directories are temporary; `update check` runs with the network denied.
#
#   bash scripts/accept/lifecycle.sh            compile the current sources and run every test
#   DOCKIT_APP=/Applications/DocKit.app bash scripts/accept/lifecycle.sh
#                                               also run the read-only checks against that bundle
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
RES="$REPO/build/DocKit.app/Contents/Resources"
[ -x "$RES/python/bin/python3.12" ] || { echo "missing bundled runtime $RES/python (run ./build.sh first)"; exit 78; }
WORK="$(mktemp -d -t dockit-lifecycle)"
PREFIX="io.github.zengtianli.DocTools.LifecycleTest"
cleanup() {
  rc=$?
  rm -rf "$WORK"
  # The preferences daemon writes an empty shell of a cleared named domain back after its processes exit.
  sleep 1
  rm -f "$HOME/Library/Preferences/$PREFIX".*.plist
  exit $rc
}
trap cleanup EXIT

TAPP="$WORK/DocKitLifecycleTest.app"
mkdir -p "$TAPP/Contents/MacOS" "$TAPP/Contents/Resources"
for item in "$RES"/*; do
  [ "$(basename "$item")" = backend ] || ln -s "$item" "$TAPP/Contents/Resources/"
done
ln -s "$REPO/backend" "$TAPP/Contents/Resources/backend"
cat > "$TAPP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DocTools</string>
<key>CFBundleIdentifier</key><string>$PREFIX</string>
<key>CFBundleName</key><string>DocKit</string>
<key>CFBundleDisplayName</key><string>DocKit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>9.8.7</string>
<key>CFBundleVersion</key><string>654</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 Sources/*.swift -o "$TAPP/Contents/MacOS/DocTools" \
  >"$WORK/compile.log" 2>&1 || { tail -20 "$WORK/compile.log"; echo "FAIL: Sources/*.swift did not compile"; exit 1; }

# Clean env: no recording, demo or quiet-launch variables may leak into the test.
env -u DOCKIT_BACKGROUND -u DOCKIT_DEMO_OP -u DOCKIT_DEMO_FILES -u DOCKIT_INPUT_DIR -u DOCKIT_CLI_NAME \
  DOCKIT_TEST_APP="$TAPP" python3 tests/test_lifecycle_cli.py "$@"
echo "PASS command words: help, status, settings, config, update check; a running app follows and never writes an old value back"
