#!/usr/bin/env bash
# Privacy acceptance for DocKit.
# Promise under test (site/index.html FAQ「文档会上传吗？」+ README):
#   文件内容在本机处理，应用不要求登录、不含遥测上传；日常本地操作可离线完成；
#   结果写入「DocKit 输出」，源文件不会被覆盖。
# Layers:
#   1 static   : no network client code in document UI/engines; shared lifecycle modules handle
#                explicit GitHub update checks and optional iCloud preference sync separately
#   2 dynamic  : real gui-run ops with Python networking blocked by an audit hook (parent AND
#                subprocess engines), zero connection/DNS attempts; optional sandbox-exec layer
#                denying network* and file writes outside the scratch dir
#   3 fs bound : inputs/fake HOME/app bundle unchanged; every Python write lands in the output dir
#                (temp dir writes are reported as allowed caches)
#   4 info     : Info.plist / entitlements network declarations (read-only report)
# Non-interactive; never launches the GUI, no mouse/keyboard/focus/clipboard use.
source "$(dirname "$0")/_common.sh"
T0=$(date +%s)

# Ship what users get: the bundled backend copy, launched the way BackendClient does (-s -B).
BUNDLE_BACKEND_DIR="$APP/Contents/Resources/backend"
[ -f "$BUNDLE_BACKEND_DIR/doc_gui_backend.py" ] || fail "包内缺少后端 $BUNDLE_BACKEND_DIR"
BACKEND="$BUNDLE_BACKEND_DIR/doc_gui_backend.py"

# ───────────────────────── 1. static scan
# Network client APIs. Anything matching fails unless explicitly allowlisted below.
SWIFT_NET='URLSession|NWConnection|NWListener|NWPathMonitor|import Network|CFNetwork|CFStream|NSURLConnection|URLRequest|WKWebView|SFSafariViewController|Alamofire|dataTask|downloadTask|uploadTask|contentsOf: *URL\(string'
PY_NET='^\s*(import|from)\s+(socket|ssl|requests|urllib3|httpx|aiohttp|http\.client|http\.server|urllib\.request|ftplib|smtplib|poplib|imaplib|telnetlib|xmlrpc|websocket|websockets|socketserver|asyncio)\b|urlopen\(|urllib\.request|http\.client|requests\.(get|post|put|Session)|create_connection|getaddrinfo|gethostbyname'
# URL literals: allowed only when they are XML namespaces, documentation examples or the Help link.
URL_ALLOW='schemas\.openxmlformats\.org|schemas\.microsoft\.com|www\.w3\.org|purl\.org|example\.com|file://'
static_hits=()
scan_dir() { # <label> <swift-glob-dir or ""> <py-dir>
  local label=$1 sdir=$2 pdir=$3 out
  if [ -n "$sdir" ]; then
    # The two vendored lifecycle modules own update metadata/download requests. The document
    # models/backends do not receive them or expose input paths/content to those modules.
    # Keep every other Swift file (including AppConfiguration.swift) in the strict scan.
    out=$(grep -nE "$SWIFT_NET" "$sdir"/*.swift | grep -vE '/AppLifecycle(UI)?\.swift:' || true)
    [ -z "$out" ] || static_hits+=("$label swift-net: $out")
    # Only allowed Swift URL literal: Help menu Link(“DocKit 使用教程”) in DocToolsApp.swift.
    # It is a SwiftUI Link — the system opens it in the user's browser only when clicked; the
    # app itself makes no request and sends no document data.
    out=$(grep -nE 'https?://' "$sdir"/*.swift | grep -vE '/AppLifecycle(UI)?\.swift:' | grep -vE "$URL_ALLOW" \
          | grep -vE 'DocToolsApp\.swift:[0-9]+: *Link\("DocKit 使用教程", destination: URL\(string: "https://app-mac-doctools\.tianli\.cyou/#install"\)!\)' || true)
    [ -z "$out" ] || static_hits+=("$label swift-url: $out")
  fi
  out=$(grep -nE "$PY_NET" "$pdir"/*.py || true)
  [ -z "$out" ] || static_hits+=("$label py-net: $out")
  # webbrowser is allowed only for file:// previews of the locally generated HTML (md_tools view).
  out=$(grep -nE 'webbrowser\.open' "$pdir"/*.py | grep -v 'webbrowser.open(f"file://' || true)
  [ -z "$out" ] || static_hits+=("$label py-webbrowser: $out")
  # Python URL literals: XML namespaces (python-docx/pptx XML), example.com in comments.
  out=$(grep -nE 'https?://' "$pdir"/*.py | grep -vE "$URL_ALLOW" || true)
  [ -z "$out" ] || static_hits+=("$label py-url: $out")
}
scan_dir repo "$REPO/Sources" "$REPO/backend"
scan_dir bundle "" "$BUNDLE_BACKEND_DIR"
if [ ${#static_hits[@]} -gt 0 ]; then printf '%s\n' "${static_hits[@]}"; fail "静态扫描发现网络代码或未放行 URL"; fi
py_files=$(ls "$REPO"/backend/*.py "$BUNDLE_BACKEND_DIR"/*.py | wc -l | tr -d ' ')
swift_files=$(ls "$REPO"/Sources/*.swift | wc -l | tr -d ' ')
bundle_drift=$( (diff -rq -x __pycache__ "$REPO/backend" "$BUNDLE_BACKEND_DIR" || true) | wc -l | tr -d ' ')
echo "static: OK ($swift_files swift, $py_files py; 文档模块仅放行帮助菜单 Link 与 XML 命名空间；共享生命周期模块负责手动更新与可选配置同步; repo/包内后端差异 $bundle_drift 项)"

# ───────────────────────── 2+3. dynamic run with network guard
IN="$WORK/in"; OUT="$WORK/out"; FAKE_HOME="$WORK/home"; TMPD="$WORK/tmp"; GUARD="$WORK/guard"
mkdir -p "$IN" "$OUT" "$FAKE_HOME" "$TMPD" "$GUARD"
make_inputs "$IN"
echo "sentinel — DocKit must not touch this" > "$FAKE_HOME/.sentinel"
GUARD_LOG="$WORK/guard.jsonl"; : > "$GUARD_LOG"
cat > "$GUARD/sitecustomize.py" <<'PY'
# Loaded by every Python process of the run (backend + subprocess engines inherit PYTHONPATH).
import json, os, sys, socket
_LOG = os.environ.get("DOCKIT_GUARD_LOG")
_NET = {"socket.connect", "socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr",
        "socket.sendto", "socket.sendmsg", "socket.bind", "urllib.Request", "http.client.connect",
        "webbrowser.open"}
_W = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC
def _rec(kind, detail):
    try:
        with open(_LOG, "a", encoding="utf-8") as f:  # the hook's own write; path is excluded later
            f.write(json.dumps({"pid": os.getpid(), "kind": kind, "detail": detail}, ensure_ascii=False) + "\n")
    except Exception:
        pass
def _hook(event, args):
    if event in _NET:
        import traceback; _rec("net", [event, repr(args)[:200], " < ".join(f"{'/'.join(f.filename.split('/')[-3:])}:{f.lineno}" for f in traceback.extract_stack()[-8:-1])])
        raise OSError(f"DocKit privacy guard: network blocked ({event})")
    if event == "open":
        path, mode, flags = (list(args) + [None, None, None])[:3]
        if isinstance(path, (str, bytes, os.PathLike)) and path != _LOG:
            writes = (isinstance(mode, str) and any(c in mode for c in "wax+")) or (isinstance(flags, int) and flags & _W)
            if writes:
                _rec("write", os.path.join(os.getcwd(), os.fsdecode(path)))
    elif event in ("os.mkdir", "os.rename", "os.remove", "os.rmdir", "shutil.copyfile", "shutil.rmtree", "os.symlink", "os.link"):
        # shutil.copyfile(src, dst) only writes dst; the other events touch every path argument.
        # Relative names are resolved against dir_fd when given (shutil.rmtree's fd walk uses
        # os.remove(name, dir_fd=fd)), otherwise against the cwd.
        fds = {"os.mkdir": [2], "os.remove": [1], "os.rmdir": [1], "os.rename": [2, 3], "os.symlink": [2], "os.link": [2, 3]}.get(event, [])
        def base(i):
            idx = fds[min(i, len(fds) - 1)] if fds else None
            fd = args[idx] if idx is not None and idx < len(args) else None
            if isinstance(fd, int) and fd >= 0:
                try:
                    import fcntl
                    return os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0])
                except Exception:
                    return f"<fd {fd}>"
            return os.getcwd()
        paths = [os.path.join(base(i), os.fsdecode(a)) if isinstance(a, (str, bytes, os.PathLike)) else None for i, a in enumerate(args[:2])]
        if event == "shutil.copyfile":
            paths = paths[1:]
        _rec("fs", [event] + paths)
    elif event in ("subprocess.Popen", "os.system", "os.posix_spawn", "os.exec"):
        exe = args[0] if args else ""
        argv = args[1] if len(args) > 1 and isinstance(args[1], (list, tuple)) else []
        _rec("proc", [event, os.fsdecode(exe) if isinstance(exe, (str, bytes, os.PathLike)) else repr(exe),
                      [os.fsdecode(x) if isinstance(x, (str, bytes, os.PathLike)) else repr(x) for x in argv][:8], os.getcwd()])
sys.addaudithook(_hook)
# Belt and braces for C-level callers that skip audit events.
def _blocked(*a, **k):
    _rec("net", ["patched", repr(a)[:200]]); raise OSError("DocKit privacy guard: network blocked")
socket.socket.connect = _blocked; socket.socket.connect_ex = _blocked
socket.create_connection = _blocked; socket.getaddrinfo = _blocked; socket.gethostbyname = _blocked
PY

# Snapshot helper: path<TAB>size<TAB>mtime<TAB>sha256 for every file under a root.
snap() { "$PY" -B - "$@" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
    for d, _, fs in os.walk(root):
        for n in fs:
            p = os.path.join(d, n)
            try:
                st = os.lstat(p); h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not os.path.islink(p) else "link"
            except OSError:
                continue
            print(f"{p}\t{st.st_size}\t{st.st_mtime_ns}\t{h}")
PY
}
snap "$IN" "$FAKE_HOME" > "$WORK/before-user.txt"
snap "$APP" > "$WORK/before-app.txt"
find "$WORK" -mindepth 1 -maxdepth 1 | sort > "$WORK/before-top.txt"

# Real ops, the way the App invokes the backend: -s -B, PYTHONDONTWRITEBYTECODE, no user site.
run_op() { # <label> <gui-run args...>; prefix via $WRAP (optional sandbox-exec)
  local label=$1; shift
  local json
  json=$(cd "$TMPD" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$FAKE_HOME" TMPDIR="$TMPD/" \
      LANG=en_US.UTF-8 PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONPATH="$GUARD" \
      DOCKIT_GUARD_LOG="$GUARD_LOG" DOCKIT_OUTPUT_DIR="$OUT" DOCKIT_SOFFICE="$WORK/no-soffice" \
      ${WRAP:-} "$PY" -s -B "$BACKEND" gui-run "$@") || fail "$label: 后端退出码非 0"
  local ok n_ok n_all
  ok=$(json_get "$json" 'd.get("ok")')
  n_ok=$(json_get "$json" 'sum(1 for r in d.get("results",[]) if r.get("ok"))')
  n_all=$(json_get "$json" 'len(d.get("results",[]))')
  [ "$ok" = "True" ] && [ "$n_all" -gt 0 ] && [ "$n_ok" = "$n_all" ] || { echo "$json" | head -c 1500; echo; fail "$label: 操作未全部成功 ($n_ok/$n_all)"; }
  echo "  op $label: ok $n_ok/$n_all"
  OPS_DONE=$((OPS_DONE+1))
}
OPS_DONE=0
echo "dynamic (audit-hook network guard):"
run_op quotes-docx   --op quotes  --files "$IN/活动说明.docx"
run_op clean-md      --op clean   --files "$IN/读书会流程.md" "$IN/补充说明.md"
run_op convert-docx  --op convert --to md   --files "$IN/活动说明.docx"
run_op convert-md    --op convert --to word --files "$IN/读书会流程.md"
run_op convert-csv   --op convert --to xlsx --files "$IN/报名统计.csv"
run_op convert-pptx  --op convert --to md   --files "$IN/读书会介绍.pptx"
run_op split-xlsx    --op split   --files "$IN/活动统计.xlsx"
run_op merge-md      --op merge   --files "$IN/读书会流程.md" "$IN/补充说明.md"
GUARD_OPS=$OPS_DONE

# Guard self-test: prove the hook is loaded and actually blocks (in a child process too).
selftest=$(env -i PATH=/usr/bin:/bin HOME="$FAKE_HOME" PYTHONPATH="$GUARD" DOCKIT_GUARD_LOG="$WORK/selftest.jsonl" "$PY" -s -B -c '
import socket, subprocess, sys
try:
    socket.create_connection(("1.1.1.1", 443), timeout=2); print("CONNECTED")
except OSError as e: print("blocked" if "privacy guard" in str(e) else "other:"+str(e))
print(subprocess.run([sys.executable, "-c", "import socket\ntry:\n socket.getaddrinfo(\"example.com\",443);print(\"RESOLVED\")\nexcept OSError as e: print(\"blocked\" if \"privacy guard\" in str(e) else \"other\")"], capture_output=True, text=True).stdout.strip())')
[ "$selftest" = $'blocked\nblocked' ] || fail "网络拦截自检失败: $selftest"

# ───────────────────────── optional sandbox-exec layer (kernel-level, covers non-Python helpers)
SANDBOX="skipped"
REAL_WORK=$(cd "$WORK" && pwd -P)
if [ -x /usr/bin/sandbox-exec ] && /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  PROFILE="$WORK/deny.sb"
  cat > "$PROFILE" <<SB
(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath "$REAL_WORK/out") (subpath "$REAL_WORK/tmp") (literal "$REAL_WORK/guard.jsonl")
       (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/tty") (regex #"^/dev/fd/"))
SB
  echo "sandbox-exec (deny network*, deny writes outside out/ tmp/):"
  WRAP="/usr/bin/sandbox-exec -f $PROFILE"
  run_op sb-quotes-docx  --op quotes  --files "$IN/活动说明.docx"
  run_op sb-convert-docx --op convert --to md --files "$IN/活动说明.docx"
  run_op sb-split-xlsx   --op split   --files "$IN/活动统计.xlsx"
  run_op sb-merge-md     --op merge   --files "$IN/读书会流程.md" "$IN/补充说明.md"
  WRAP=""
  # Sandbox self-test: a network attempt inside the profile must fail.
  if /usr/bin/sandbox-exec -f "$PROFILE" /usr/bin/curl -s -m 3 -o /dev/null https://example.com 2>/dev/null; then
    fail "sandbox-exec 配置未阻断网络"
  fi
  SANDBOX="passed ($((OPS_DONE-GUARD_OPS)) ops)"
else
  echo "sandbox-exec: 不可用或已处于沙箱内，跳过该层"
fi

# ───────────────────────── evaluate guard log + filesystem boundary
eval_json=$("$PY" -B - "$GUARD_LOG" "$REAL_WORK" "$WORK" <<'PY'
import json, os, sys
log, real, work = sys.argv[1:4]
rows = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
def norm(p):
    p = os.path.realpath(p) if p else ""
    return p
out, tmp = os.path.join(real, "out"), os.path.join(real, "tmp")
inside = lambda p, root: p == root or p.startswith(root + os.sep)
# urllib3 (pulled in by markitdown -> requests at import time) probes IPv6 support with
# socket.bind(("::1", 0)) in urllib3/util/connection.py:_has_ipv6. A loopback bind to an
# ephemeral port sends no packets and contacts no host, so it is reported, not failed.
# (The guard still raised on it; urllib3 swallows the error and the op succeeded.)
def loopback_probe(d):
    return d[0] == "socket.bind" and ("('::1', 0)" in d[1] or "('127.0.0.1', 0)" in d[1])
net_all = [r["detail"] for r in rows if r["kind"] == "net"]
probes = [d for d in net_all if loopback_probe(d)]
net = [d for d in net_all if not loopback_probe(d)]
writes = sorted({norm(r["detail"]) for r in rows if r["kind"] == "write"})
fs = [r["detail"] for r in rows if r["kind"] == "fs"]
fs_paths = sorted({norm(p) for d in fs for p in d[1:] if p})
procs = [r["detail"] for r in rows if r["kind"] == "proc"]
allowed_dev = ("/dev/null",)
bad_writes = [p for p in writes + fs_paths if not (inside(p, out) or inside(p, tmp) or p in allowed_dev)]
tmp_writes = [p for p in writes + fs_paths if inside(p, tmp)]
py = os.path.realpath(sys.executable)
# Allowed children: the bundled interpreter (engine subprocesses) and /usr/bin/xattr, which
# file_ops.clear_quarantine uses to drop com.apple.quarantine from the produced file (local
# metadata only). Its target must itself be inside the output dir.
foreign_procs, xattr_calls = [], 0
for d in procs:
    exe, argv, cwd = d[1], d[2], d[3]
    name = os.path.basename(exe)
    if os.path.realpath(exe if os.path.isabs(exe) else os.path.join(cwd, exe)) == py or name.startswith("python3"):
        continue
    if name == "xattr" and argv[:3] == ["xattr", "-d", "com.apple.quarantine"] and len(argv) == 4 \
            and inside(norm(os.path.join(cwd, argv[3])), out):
        xattr_calls += 1
        continue
    foreign_procs.append(" ".join([exe] + argv))
foreign_procs = sorted(set(foreign_procs))
print(json.dumps({"events": len(rows), "net_attempts": net, "loopback_bind_probes": len(probes), "probe_sites": sorted({d[2].split(" < ")[-1] for d in probes if len(d) > 2}), "write_paths": len(writes), "fs_ops": len(fs),
                  "bad_writes": bad_writes, "tmp_writes": sorted(set(p.replace(real, "$WORK") for p in tmp_writes)),
                  "subprocesses": len(procs), "xattr_quarantine_clears": xattr_calls, "non_python_subprocesses": foreign_procs}, ensure_ascii=False))
PY
)
net_n=$(json_get "$eval_json" 'len(d["net_attempts"])')
[ "$net_n" = 0 ] || { json_get "$eval_json" 'd["net_attempts"]'; fail "检测到 $net_n 次网络尝试"; }
bad_n=$(json_get "$eval_json" 'len(d["bad_writes"])')
[ "$bad_n" = 0 ] || { json_get "$eval_json" 'd["bad_writes"]'; fail "Python 在输出目录外写入 $bad_n 处"; }
probes=$(json_get "$eval_json" 'd["loopback_bind_probes"]')
[ "$probes" = 0 ] || echo "note: $probes 次回环 IPv6 能力探测 (urllib3 导入时 bind ::1:0，无外连): $(json_get "$eval_json" 'd["probe_sites"]')"
foreign=$(json_get "$eval_json" 'd["non_python_subprocesses"]')
[ "$foreign" = "[]" ] || fail "启动了非打包 Python 的子进程: $foreign"

# Inputs and fake HOME byte-identical; app bundle unchanged; nothing new at WORK top level.
snap "$IN" "$FAKE_HOME" > "$WORK/after-user.txt"
snap "$APP" > "$WORK/after-app.txt"
cmp -s "$WORK/before-user.txt" "$WORK/after-user.txt" || { diff "$WORK/before-user.txt" "$WORK/after-user.txt" | head; fail "输入目录或 HOME 发生变化"; }
cmp -s "$WORK/before-app.txt" "$WORK/after-app.txt" || { diff "$WORK/before-app.txt" "$WORK/after-app.txt" | head; fail "应用包内容被运行改动"; }
new_top=$(find "$WORK" -mindepth 1 -maxdepth 1 | sort | comm -13 "$WORK/before-top.txt" - | grep -vE '/(guard\.jsonl|selftest\.jsonl|deny\.sb|before-.*|after-.*)$' || true)
[ -z "$new_top" ] || fail "输出目录外出现新文件: $new_top"
out_files=$(find "$OUT" -type f | wc -l | tr -d ' ')
[ "$out_files" -gt 0 ] || fail "输出目录没有产物"
tmp_left=$(find "$TMPD" -mindepth 1 | sed "s|$WORK|\$WORK|" | head -20)
echo "fs boundary: OK (输入/HOME/应用包字节不变，输出 $out_files 个文件；临时目录残留: ${tmp_left:-无})"

# ───────────────────────── 4. Info.plist / entitlements (report only)
ent=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
net_ent="none"
if echo "$ent" | grep -q 'com.apple.security.network'; then net_ent=$(echo "$ent" | grep -oE 'com\.apple\.security\.network\.[a-z]+' | sort -u | tr '\n' ' '); fi
sandboxed=$(echo "$ent" | grep -q 'com.apple.security.app-sandbox' && echo yes || echo no)
plist_net=$(plutil -p "$APP/Contents/Info.plist" | grep -iE 'NSAppTransport|NSLocalNetwork|NSBonjour|NSAllowsArbitrary' | tr -d '\n' || true)
echo "info: 网络 entitlements=$net_ent, app-sandbox=$sandboxed, Info.plist 网络键=${plist_net:-无}"

SECS=$(( $(date +%s) - T0 ))
SUMMARY="隐私通过：静态无网络代码；$OPS_DONE 次真实操作零外连/DNS 尝试（回环探测 ${probes} 次）、写入仅限输出目录；sandbox-exec ${SANDBOX}；${SECS}s"
accept_detail true "$SUMMARY" "$("$PY" -c 'import json,sys; e=json.loads(sys.argv[1]); print(json.dumps({"static":{"swift_files":int(sys.argv[2]),"py_files":int(sys.argv[3]),"allowlist":["DocToolsApp.swift Help Link https://app-mac-doctools.tianli.cyou/#install (user-clicked, opened by system browser)","md_tools webbrowser.open(file://local html)","XML namespace / example.com literals"],"repo_vs_bundle_backend_diffs":int(sys.argv[4])},"dynamic":{"ops":int(sys.argv[5]),"guard_ops":int(sys.argv[6]),"sandbox_exec":sys.argv[7],**e},"entitlements":{"network":sys.argv[8].strip(),"app_sandbox":sys.argv[9]},"seconds":int(sys.argv[10])},ensure_ascii=False))' "$eval_json" "$swift_files" "$py_files" "$bundle_drift" "$OPS_DONE" "$GUARD_OPS" "$SANDBOX" "$net_ent" "$sandboxed" "$SECS")"
echo "PASS privacy: $SUMMARY"
