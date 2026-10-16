#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
_XCODE_ENV_SH=/Users/tianli/Dev/tools/dev/lib/tools/macapp/xcode_env.sh
if [ -f "$_XCODE_ENV_SH" ]; then
  source "$_XCODE_ENV_SH"
  xcode_env_use macosx
fi
TMP="$(mktemp -d -t dockit-state)"
trap 'rm -rf "$TMP"' EXIT
APP="${DOCKIT_APP:-$DIR/build/DocKit.app}"
PY="$APP/Contents/Resources/python/bin/python3.12"
"$PY" -B scripts/make-demo.py "$TMP/Inputs"
# Keep SDK compilation sequential inside Chapter's original build lane.
JOBS="${DOCKIT_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
CHECK_JOBS="$JOBS"
RC=0
(
  xcrun swiftc -j "$CHECK_JOBS" -parse-as-library Sources/Models.swift Sources/BackendClient.swift Sources/ViewModel.swift tests/StateCheck.swift -o "$TMP/state-check"
  DOCKIT_OUTPUT_DIR="$TMP/Outputs" "$TMP/state-check" "$APP/Contents/Resources/backend/doc_gui_backend.py" "$TMP/Inputs/活动说明.docx"
) >"$TMP/state.log" 2>&1 || RC=1
(
  xcrun swiftc -j "$CHECK_JOBS" -parse-as-library Sources/Models.swift Sources/BackendClient.swift Sources/ViewModel.swift tests/PreferencesCheck.swift -o "$TMP/preferences-check"
  "$TMP/preferences-check"
) >"$TMP/preferences.log" 2>&1 || RC=1
# Command words and the running app are exercised off screen with temporary settings.
DOCKIT_BUILD_JOBS="$CHECK_JOBS" bash scripts/accept/lifecycle.sh >"$TMP/lifecycle.log" 2>&1 || RC=1
cat "$TMP/state.log" "$TMP/preferences.log" "$TMP/lifecycle.log"
exit "$RC"
