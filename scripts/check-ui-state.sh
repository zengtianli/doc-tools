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
PY="$DIR/build/DocKit.app/Contents/Resources/python/bin/python3.12"
"$PY" -B scripts/make-demo.py "$TMP/Inputs"
xcrun swiftc -parse-as-library Sources/Models.swift Sources/BackendClient.swift Sources/ViewModel.swift tests/StateCheck.swift -o "$TMP/state-check"
DOCKIT_OUTPUT_DIR="$TMP/Outputs" "$TMP/state-check" "$DIR/build/DocKit.app/Contents/Resources/backend/doc_gui_backend.py" "$TMP/Inputs/活动说明.docx"
