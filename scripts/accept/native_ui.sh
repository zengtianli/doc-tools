#!/usr/bin/env bash
# native_ui: in-process, offscreen UI self-test of the real SwiftUI views.
# Compiles Sources/*.swift into a temporary .app whose Resources symlink to the
# built bundle (bundled Python runtime) and repo backend, then runs `--ui-self-test`.
# The test never orders a window front, never activates, never synthesizes input.
source "$(dirname "$0")/_common.sh"

RES="$APP/Contents/Resources"
[ -f "$RES/backend/doc_gui_backend.py" ] || { echo "缺少打包后端 $RES/backend（先 ./build.sh）"; exit 78; }

T0=$(date +%s)
TAPP="$WORK/DocKitSelfTest.app"
mkdir -p "$TAPP/Contents/MacOS"
# Bundled Python runtime + the repo's current backend, so the check covers uncommitted backend
# fixes too; everything is symlinked read-only and build/DocKit.app is not modified.
mkdir -p "$TAPP/Contents/Resources"
for item in "$RES"/*; do
  [ "$(basename "$item")" = backend ] || ln -s "$item" "$TAPP/Contents/Resources/"
done
ln -s "$REPO/backend" "$TAPP/Contents/Resources/backend"
cat > "$TAPP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DocKit</string>
<key>CFBundleIdentifier</key><string>io.github.zengtianli.DocTools.SelfTest</string>
<key>CFBundleName</key><string>DocKit</string>
<key>CFBundleDisplayName</key><string>DocKit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
BIN="$TAPP/Contents/MacOS/DocKit"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx15.0 Sources/*.swift -o "$BIN" \
  >"$WORK/compile.log" 2>&1 || { tail -20 "$WORK/compile.log"; fail "Sources/*.swift 编译失败"; }
T1=$(date +%s)

make_inputs "$WORK/inputs"
SHOTS="$OUT_DIR"
rm -f "$SHOTS"/native_ui-*.png

# Clean env: no recording/demo variables may leak into the self-test.
set +e
env -u DOCKIT_BACKGROUND -u DOCKIT_DEMO_OP -u DOCKIT_DEMO_FILES -u DOCKIT_INPUT_DIR \
  DOCKIT_SELFTEST_INPUT_DIR="$WORK/inputs" SOP_OUT_DIR="$SHOTS" \
  "$PY" - "$BIN" "$WORK/selftest.out" <<'PY'
import subprocess, sys
bin_, out = sys.argv[1:3]
try:
    p = subprocess.run([bin_, "--ui-self-test"], capture_output=True, text=True, timeout=120)
    open(out, "w").write(p.stdout + "\n#STDERR\n" + p.stderr[-4000:] + f"\n#RC {p.returncode}\n")
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    open(out, "w").write("#TIMEOUT 120s\n")
    sys.exit(124)
PY
RC=$?
set -e
T2=$(date +%s)

LINE="$(grep -m1 '^{' "$WORK/selftest.out" || true)"
[ -n "$LINE" ] || { cat "$WORK/selftest.out"; fail "自检没有输出 JSON（rc=${RC}）"; }
echo "$LINE"
"$PY" - "$LINE" "$RC" "$((T1-T0))" "$((T2-T1))" "$OUT_DIR/$CHECK.detail.json" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); rc = int(sys.argv[2])
bad = [c for c in d["checks"] if not c["ok"]]
ok = bool(d.get("ok")) and rc == 0 and not bad
summary = (f"原生界面离屏自检 {d.get('passed')}/{d.get('total')} 通过；"
           f"截图 {len(d.get('screenshots', []))} 张；编译 {sys.argv[3]}s，运行 {sys.argv[4]}s")
if not ok:
    summary += "；失败：" + "、".join(c["name"] for c in bad) + (d.get("error") and f"；{d['error']}" or "")
detail = {"ok": ok, "summary": summary, "rc": rc, "compile_s": int(sys.argv[3]), "run_s": int(sys.argv[4]),
          "checks": d["checks"], "screenshots": d.get("screenshots", []), "run_ms": d.get("run_ms"),
          "method": "in-process NSHostingView in never-ordered borderless NSWindow, activation policy .prohibited; "
                    "notifications .consoleRefresh/.tlPaletteToggle posted directly; no synthesized input"}
open(sys.argv[5], "w", encoding="utf-8").write(json.dumps(detail, ensure_ascii=False, indent=2) + "\n")
print(summary)
sys.exit(0 if ok else 1)
PY
