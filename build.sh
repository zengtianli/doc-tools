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
xcrun swiftc -j "${DOCKIT_BUILD_JOBS:-$(sysctl -n hw.ncpu)}" -O -parse-as-library -target arm64-apple-macosx15.0 Sources/*.swift -o build/DocTools
# DOCKIT_OUT=build/perf-next ./build.sh puts the app, archive and manifest there instead of build/ + dist/.
python3 scripts/package.py ${DOCKIT_OUT:+--out "$DOCKIT_OUT"}
# --install: only a package any Mac can run goes into /Applications. With a Developer ID certificate
# package.py has signed the distribution build; notarize, staple, then install (both steps fail closed).
# An ad-hoc build (no certificate on this Mac) stays in the build directory as a local trial.
if [ "${1:-}" = "--install" ]; then
  python3 scripts/notarize.py ${DOCKIT_OUT:+--dir "$DOCKIT_OUT"}
  python3 scripts/install.py --app "${DOCKIT_OUT:-build}/DocKit.app"
fi
