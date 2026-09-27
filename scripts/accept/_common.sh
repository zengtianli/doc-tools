# Shared helpers for DocKit fixed acceptance scripts (sourced, not executed).
# Contract (app_sop accept): run from repo root; exit 0 = pass, 78 = no acceptor, other = fail.
# Writes $SOP_OUT_DIR/<check>.detail.json with a "summary" when accept_detail is called.
set -euo pipefail
ACCEPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ACCEPT_DIR/../.." && pwd)"
cd "$REPO"
CHECK="${SOP_CHECK:-$(basename "${0%.*}")}"
OUT_DIR="${SOP_OUT_DIR:-$REPO/perf/acceptance}"
mkdir -p "$OUT_DIR"
APP="$REPO/build/DocKit.app"
# Bundled runtime is what users get; fall back to repo python only for the backend-only checks.
PY="$APP/Contents/Resources/python/bin/python3.12"
BACKEND="$REPO/backend/doc_gui_backend.py"
[ -x "$PY" ] || { echo "缺少打包运行时 ${PY}（先 ./build.sh）"; exit 78; }
WORK="$(mktemp -d -t "dockit-accept-$CHECK")"
# Keep the script's own exit status: a crash (e.g. set -u) must never be recorded as a pass.
trap 'rc=$?; rm -rf "$WORK"; exit $rc' EXIT

# Fictional inputs only (scripts/make-demo.py): 活动说明.docx, 读书会流程.md, 补充说明.md, …
make_inputs() { "$PY" -B scripts/make-demo.py "$1" >/dev/null; }

# backend <args...>: run the GUI backend exactly as the App does; JSON envelope on stdout.
backend() { "$PY" -B "$BACKEND" "$@"; }

# json_get <json> <python-expr over d>: print expression result.
json_get() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

fail() { echo "FAIL: $*"; accept_detail false "$*"; exit 1; }

# accept_detail <ok:true|false> <summary> [extra-json-object]
accept_detail() {
  "$PY" - "$OUT_DIR/$CHECK.detail.json" "$1" "$2" "${3:-{\}}" <<'PY'
import json, sys
path, ok, summary, extra = sys.argv[1:5]
data = {"ok": ok == "true", "summary": summary, **json.loads(extra)}
open(path, "w", encoding="utf-8").write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}
