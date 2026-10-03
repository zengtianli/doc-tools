#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
LIFECYCLE_VENDOR="${APP_LIFECYCLE_VENDOR:-$HOME/Dev/tools/dev/lib/tools/macapp/swift-shared/vendor-lifecycle.py}"
if [ -f "$LIFECYCLE_VENDOR" ]; then
  python3 "$LIFECYCLE_VENDOR" --platform mac --target-source-dir "$DIR/Sources"
fi
_XCODE_ENV_SH="$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh"
if [ -f "$_XCODE_ENV_SH" ]; then
  source "$_XCODE_ENV_SH"
  xcode_env_use macosx
fi
xcrun --sdk macosx --show-sdk-path >/dev/null
python3 scripts/bundle-runtime.py
mkdir -p build
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx15.0 Sources/*.swift -o build/DocTools
# DOCKIT_OUT=build/perf-next ./build.sh puts the app, archive and manifest there instead of build/ + dist/.
python3 scripts/package.py ${DOCKIT_OUT:+--out "$DOCKIT_OUT"}
if [ "${1:-}" = "--install" ]; then
  echo 'Built build/DocKit.app. Drag this app into Applications to install.'
fi
