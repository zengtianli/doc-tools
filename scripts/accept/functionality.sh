#!/usr/bin/env bash
# DocKit functionality acceptance: every op from `gui-ops` runs end to end on fictional inputs
# through the same backend entry the App uses (gui-run, JSON envelope), and the produced files
# really contain the expected change. No GUI, no browser (DOCKIT_NO_OPEN=1), no network.
source "$(dirname "$0")/_common.sh"
START=$(date +%s)

IN="$WORK/in"; ENV_DIR="$WORK/env"; mkdir -p "$ENV_DIR"
make_inputs "$IN"
export DOCKIT_OUTPUT_DIR="$WORK/out" DOCKIT_NO_OPEN=1

# Fingerprint the originals: gui-run must only ever work on staged copies.
"$PY" - "$IN" > "$WORK/before.sha" <<'PY'
import hashlib, pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob("*")):
    print(hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "dir", p.relative_to(sys.argv[1]))
PY

backend gui-ops > "$ENV_DIR/gui-ops.json"
# run <key> <gui-run args...>: store the envelope for the verifier.
run() { local key="$1"; shift; backend gui-run "$@" > "$ENV_DIR/$key.json"; }

run clean        --op clean --files "$IN/活动说明.docx" "$IN/读书会流程.md" "$IN/读书会介绍.pptx" "$IN/不支持的图片.jpg"
run quotes       --op quotes --files "$IN/活动说明.docx"
run quotes_nohdr --op quotes --opt scope.headers=0 --files "$IN/活动说明.docx"
run bad_opt      --op quotes --opt rule.nope=1 --files "$IN/活动说明.docx"
run fontunify    --op fontunify --files "$IN/读书会介绍.pptx"
run lowercase    --op lowercase --files "$IN/活动说明.docx" "$IN/活动统计.xlsx"
run stripchrome  --op stripchrome --files "$IN/活动说明.docx"
run conv_md      --op convert --to md   --files "$IN/活动说明.docx" "$IN/读书会介绍.pptx"
run conv_word    --op convert --to word --files "$IN/读书会流程.md" "$IN/活动说明.docx"
run conv_xlsx    --op convert --to xlsx --files "$IN/报名统计.csv"
run conv_csv     --op convert --to csv  --files "$IN/活动统计.xlsx"
run conv_txt     --op convert --to txt  --files "$IN/报名统计.csv"
run conv_noto    --op convert --files "$IN/活动说明.docx"
run split        --op split --files "$IN/读书会流程.md" "$IN/活动统计.xlsx"
run merge        --op merge --files "$IN/读书会流程.md" "$IN/补充说明.md"
run view         --op view --files "$IN/读书会流程.md"

set +e
"$PY" - "$ENV_DIR" "$IN" "$WORK" > "$WORK/verify.out" <<'PY'
import csv, json, pathlib, re, shutil, sys, hashlib
from docx import Document
from openpyxl import load_workbook
from pptx import Presentation

env_dir, IN, WORK = map(pathlib.Path, sys.argv[1:4])
fails, verified = [], []

def env(key):
    return json.loads((env_dir / f"{key}.json").read_text(encoding="utf-8"))

def check(cond, msg):
    if not cond:
        fails.append(msg)
    return bool(cond)

def row(key, name):
    """Result row for an input file name; asserts the row succeeded and outputs exist on disk."""
    e = env(key)
    check(e.get("ok"), f"{key}: envelope not ok: {e.get('error')}")
    rows = [r for r in e.get("results", []) if pathlib.Path(r["input"]).name == name or r["name"] == name]
    if not check(rows, f"{key}: no result row for {name}"):
        return []
    r = rows[0]
    check(r["ok"], f"{key}/{name}: row failed: {r.get('message')}")
    outs = [pathlib.Path(o) for o in r["outputs"]]
    check(outs and all(o.exists() for o in outs), f"{key}/{name}: outputs missing on disk: {r['outputs']}")
    check(all(str(o).startswith(str(WORK / "out")) or str(o).startswith("/private" + str(WORK / "out"))
              or str(o.resolve()).startswith(str((WORK / "out").resolve())) for o in outs),
          f"{key}/{name}: output outside DOCKIT_OUTPUT_DIR: {r['outputs']}")
    return outs

def pick(outs, suffix):
    hit = [o for o in outs if o.name.endswith(suffix)]
    return hit[0] if hit else None

def docx_text(p):
    d = Document(p)
    parts = [x.text for x in d.paragraphs]
    parts += [c.text for t in d.tables for r in t.rows for c in r.cells]
    return "\n".join(parts)

def header_text(p):
    return "\n".join(par.text for s in Document(p).sections for par in s.header.paragraphs)

def pptx_texts(p):
    return [sh.text_frame.text for s in Presentation(p).slides for sh in s.shapes if sh.has_text_frame]

src_docx = docx_text(IN / "活动说明.docx")
check('"读书与日常"' in src_docx and "120 平方米" in src_docx, "fixture: expected ASCII quotes/units in 活动说明.docx")

# ── gui-ops: the menu the App renders; every id must be exercised below.
ops = env("gui-ops")
check(ops.get("ok"), "gui-ops not ok")
op_ids = [o["id"] for o in ops.get("ops", [])]
check(len(op_ids) == 9, f"gui-ops: expected 9 ops, got {len(op_ids)}: {op_ids}")

# ── clean (规范化): quotes + punctuation + units on docx (body, table, header), md, pptx.
outs = row("clean", "活动说明.docx")
f = pick(outs, "_fixed.docx")
if check(f, f"clean/docx: no _fixed.docx in {outs}"):
    t, h = docx_text(f), header_text(f)
    check("“读书与日常”" in t, "clean/docx: body quotes not converted to “”")
    check('"' not in t, "clean/docx: ASCII double quote left in body/table")
    check("联系人说：" in t, "clean/docx: ASCII colon not converted to ：")
    check("m²" in t and "平方米" not in t, "clean/docx: 平方米 not converted to m²")
    check("主题：" in t and "“一本好书”" in t, "clean/docx: table cell not normalised")
    check("https://example.com/signup?day=1" in t and "hello@example.com" in t, "clean/docx: URL/e-mail altered")
    check("“虚构演示”" in h, f"clean/docx: header quotes not converted: {h!r}")
    verified.append("clean:docx")
outs = row("clean", "读书会流程.md")
f = pick(outs, "_fixed.md")
if check(f, f"clean/md: no _fixed.md in {outs}"):
    t = f.read_text(encoding="utf-8")
    check("# 读书会流程" in t and "带走一条新想法" in t, "clean/md: content lost")
    verified.append("clean:md")
outs = row("clean", "读书会介绍.pptx")
real = [o for o in outs if o.suffix == ".pptx"]
if check(real, f"clean/pptx: envelope reports no .pptx output (reported {[o.name for o in outs]}) — "
               "the App would open the untouched .backup instead of the normalised copy"):
    check(any("“读书与日常”" in "".join(pptx_texts(o)) for o in real), "clean/pptx: quotes not converted")
    verified.append("clean:pptx")
jpg = [r for r in env("clean")["results"] if r["name"] == "不支持的图片.jpg"]
check(jpg and not jpg[0]["ok"] and "不支持" in jpg[0]["message"], f"clean/jpg: unsupported file not rejected cleanly: {jpg}")

# ── quotes (引号统一): only quotes change; punctuation/units untouched; scope option honoured.
outs = row("quotes", "活动说明.docx")
f = pick(outs, "_fixed.docx")
if check(f, "quotes/docx: no _fixed.docx"):
    t = docx_text(f)
    check("“读书与日常”" in t and '"' not in t, "quotes/docx: quotes not converted")
    check("联系人说:" in t and "120 平方米" in t, "quotes/docx: touched punctuation/units (should be quotes only)")
    check("“虚构演示”" in header_text(f), "quotes/docx: header quotes not converted by default")
    verified.append("quotes:docx")
outs = row("quotes_nohdr", "活动说明.docx")
f = pick(outs, "_fixed.docx")
if check(f, "quotes/scope.headers=0: no output"):
    check("“读书与日常”" in docx_text(f), "quotes/scope.headers=0: body not converted")
    check('"虚构演示"' in header_text(f), "quotes/scope.headers=0: header changed despite option off")
    verified.append("quotes:option")
b = env("bad_opt")
check(b.get("ok") is False and "未知选项" in b.get("error", ""), f"quotes: unknown option not rejected: {b}")

# ── fontunify (字体统一): every run set to one font, text unchanged.
outs = row("fontunify", "读书会介绍.pptx")
f = [o for o in outs if o.suffix == ".pptx"]
if check(f, "fontunify: no .pptx output"):
    p = Presentation(f[0])
    fonts = {r.font.name for s in p.slides for sh in s.shapes if sh.has_text_frame
             for para in sh.text_frame.paragraphs for r in para.runs}
    check(len(fonts) == 1 and None not in fonts, f"fontunify: fonts not unified: {fonts}")
    check(pptx_texts(f[0]) == pptx_texts(IN / "读书会介绍.pptx"), "fontunify: text changed")
    verified.append("fontunify:pptx")

# ── lowercase (英文小写整理): copy saved as *_lower; text equals lower() of source.
outs = row("lowercase", "活动说明.docx")
f = pick(outs, "_lower.docx")
if check(f, "lowercase/docx: no _lower.docx"):
    check(docx_text(f) == src_docx.lower(), "lowercase/docx: text != source.lower()")
    verified.append("lowercase:docx")
outs = row("lowercase", "活动统计.xlsx")
f = pick(outs, "_lower.xlsx")
if check(f, "lowercase/xlsx: no _lower.xlsx"):
    vals = lambda p: [[c for c in r] for ws in load_workbook(p).worksheets for r in ws.iter_rows(values_only=True)]
    low = [[c.lower() if isinstance(c, str) else c for c in r] for r in vals(IN / "活动统计.xlsx")]
    check(vals(f) == low, "lowercase/xlsx: cells != source.lower()")
    verified.append("lowercase:xlsx")

# ── stripchrome (清页眉页脚): header gone, body identical.
outs = row("stripchrome", "活动说明.docx")
f = pick(outs, "_fixed.docx")
if check(f, "stripchrome: no _fixed.docx"):
    check("虚构演示" not in header_text(f), "stripchrome: header text still present")
    check(docx_text(f) == src_docx, "stripchrome: body text changed")
    verified.append("stripchrome:docx")

# ── convert (格式转换) across all five targets.
outs = row("conv_md", "活动说明.docx")
f = pick(outs, ".md")
if check(f, "convert docx→md: no .md"):
    t = f.read_text(encoding="utf-8")
    check("星河读书会 · 活动说明" in t and "| 签到 | 09:30 |" in t, "convert docx→md: text/table missing")
    verified.append("convert:docx→md")
outs = row("conv_md", "读书会介绍.pptx")
f = pick(outs, ".md")
if check(f, "convert pptx→md: no .md"):
    check("星河读书会" in f.read_text(encoding="utf-8"), "convert pptx→md: slide text missing")
    verified.append("convert:pptx→md")
outs = row("conv_word", "读书会流程.md")
f = pick(outs, ".docx")
if check(f, "convert md→word: no .docx"):
    d = Document(f)
    t = "\n".join(p.text for p in d.paragraphs)
    check("读书会流程" in t and "带走一条新想法" in t, "convert md→word: text missing")
    check(any(p.style.name.lower().startswith("heading") or "标题" in p.style.name for p in d.paragraphs),
          "convert md→word: no heading styles")
    verified.append("convert:md→word")
outs = row("conv_word", "活动说明.docx")
f = pick(outs, "_styled.docx")
if check(f, "convert docx→word: no _styled.docx"):
    check("星河读书会" in docx_text(f), "convert docx→word: text missing")
    verified.append("convert:docx→word")
outs = row("conv_xlsx", "报名统计.csv")
f = pick(outs, ".xlsx")
if check(f, "convert csv→xlsx: no .xlsx"):
    rows = [list(r) for r in load_workbook(f).active.iter_rows(values_only=True)]
    check(rows and [str(c) for c in rows[0]] == ["活动", "人数", "场地面积"]
          and any("观影会" in [str(c) for c in r] for r in rows), f"convert csv→xlsx: cells wrong: {rows}")
    verified.append("convert:csv→xlsx")
outs = row("conv_csv", "活动统计.xlsx")
csvs = sorted(o for o in outs if o.suffix == ".csv")
if check(len(csvs) == 2, f"convert xlsx→csv: expected 2 sheet csvs, got {outs}"):
    body = {o.name: list(csv.reader(o.open(encoding="utf-8-sig"))) for o in csvs}
    check(any(["参加人数", "24"] in v for v in body.values()) and any(["参加人数", "18"] in v for v in body.values()),
          f"convert xlsx→csv: sheet data wrong: {body}")
    verified.append("convert:xlsx→csv")
outs = row("conv_txt", "报名统计.csv")
f = pick(outs, ".txt")
if check(f, "convert csv→txt: no .txt"):
    t = f.read_text(encoding="utf-8")
    check("读书会" in t and "观影会" in t, "convert csv→txt: data missing")
    verified.append("convert:csv→txt")
n = env("conv_noto")
check(n.get("ok") is False and "--to" in n.get("error", ""), f"convert without --to not rejected: {n}")

# ── split (拆分): md by heading, xlsx by sheet.
outs = row("split", "读书会流程.md")
parts = sorted(p for o in outs for p in ([o] if o.is_file() else o.rglob("*.md")))
if check(parts, "split/md: no parts"):
    joined = "\n".join(p.read_text(encoding="utf-8") for p in parts)
    check(all(s in joined for s in ("## 签到", "## 分享", "## 自由交流", "带走一条新想法")), "split/md: content lost")
    verified.append("split:md")
outs = row("split", "活动统计.xlsx")
xl = [o for o in outs if o.suffix == ".xlsx"]
if check(len(xl) == 2, f"split/xlsx: expected 2 files, got {outs}"):
    check(all(len(load_workbook(o).sheetnames) == 1 for o in xl), "split/xlsx: parts not single-sheet")
    verified.append("split:xlsx")

# ── merge (合并): both md sources in one file.
outs = row("merge", "合并 2 个文件")
f = pick(outs, ".md")
if check(f, "merge: no merged .md"):
    t = f.read_text(encoding="utf-8")
    check("# 读书会流程" in t and "# 补充说明" in t and "带走一条新想法" in t and "不含真实名单" in t,
          "merge: content from both inputs missing")
    verified.append("merge:md")

# ── view (预览): md rendered to HTML (browser suppressed); path comes from the log.
v = env("view")
row("view", "读书会流程.md")
m = re.findall(r"(/\S+\.html)", v.get("log", ""))
if check(m and pathlib.Path(m[-1]).exists(), f"view: rendered HTML not found (log: {v.get('log','')[-200:]!r})"):
    html = pathlib.Path(m[-1])
    t = html.read_text(encoding="utf-8")
    check("<h2" in t and "自由交流" in t, "view: HTML missing rendered headings/content")
    verified.append("view:md→html")
    if html.parent.name.startswith("tmp"):
        shutil.rmtree(html.parent, ignore_errors=True)  # renderer's own temp dir; don't leave residue

# ── coverage: each gui-ops id verified at least once.
covered = {v.split(":")[0] for v in verified}
check(set(op_ids) <= covered, f"ops not verified: {sorted(set(op_ids) - covered)}")

# ── no side outputs next to the originals (DOCKIT_OUTPUT_DIR is honoured).
extra = [p.name for p in IN.iterdir()]
check(not (IN / "DocKit 输出").exists(), f"outputs leaked next to inputs: {extra}")

print(json.dumps({"fails": fails, "verified": verified, "ops": op_ids}, ensure_ascii=False))
sys.exit(1 if fails else 0)
PY
VRC=$?
set -e

"$PY" - "$IN" > "$WORK/after.sha" <<'PY'
import hashlib, pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob("*")):
    print(hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "dir", p.relative_to(sys.argv[1]))
PY

RESULT="$(tail -n 1 "$WORK/verify.out")"
[ -n "$RESULT" ] || { cat "$WORK/verify.out"; fail "verifier crashed"; }
ELAPSED=$(( $(date +%s) - START ))
FAILS="$(json_get "$RESULT" '"; ".join(d["fails"])')"
if ! diff -q "$WORK/before.sha" "$WORK/after.sha" >/dev/null; then
  FAILS="${FAILS:+$FAILS; }inputs modified: $(diff "$WORK/before.sha" "$WORK/after.sha" | tr '\n' ' ')"
fi
if [ "$VRC" -ne 0 ] || [ -n "$FAILS" ]; then
  json_get "$RESULT" '"\n".join("  - " + f for f in d["fails"])'
  fail "functionality: $FAILS"
fi

VERIFIED="$(json_get "$RESULT" '", ".join(d["verified"])')"
NCHK="$(json_get "$RESULT" 'len(d["verified"])')"
EXTRA="$("$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps({"ops": d["ops"], "verified": d["verified"], "inputs_unchanged": True, "seconds": int(sys.argv[2])}, ensure_ascii=False))' "$RESULT" "$ELAPSED")"
accept_detail true "9/9 个操作经 gui-run 实跑并核对产出内容（${NCHK} 项）：${VERIFIED}；原件 sha256 不变" "$EXTRA"
echo "PASS functionality: ${NCHK} checks over 9 ops (${VERIFIED}); inputs unchanged; ${ELAPSED}s"
