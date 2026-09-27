#!/usr/bin/env bash
# Failure & recovery acceptance: drives the same backend entry the App uses
# (doc_gui_backend.py gui-run), no GUI, no network, fictional inputs only.
# Proves: bad input yields exit 0 + valid JSON + Chinese error; one bad file in a
# batch does not sink the others; outputs never overwrite earlier results; the
# user's originals stay byte-identical; a re-run on good input succeeds.
source "$(dirname "$0")/_common.sh"

START=$(date +%s)
IN="$WORK/in"
make_inputs "$IN"
export DOCKIT_OUTPUT_DIR="$WORK/out"
mkdir -p "$DOCKIT_OUTPUT_DIR"
head -c 4096 /dev/urandom > "$IN/损坏.docx"   # random bytes, not a zip
DOCX="$IN/活动说明.docx"; MD="$IN/读书会流程.md"; JPG="$IN/不支持的图片.jpg"; BAD="$IN/损坏.docx"

hash_inputs() { (cd "$IN" && shasum -a 256 * | sort); }
BEFORE_HASH="$(hash_inputs)"
CASES=()

# run_json <args...>: run backend, require exit 0 and one valid JSON object on stdout.
run_json() {
  local out rc
  set +e; out="$(backend "$@" 2>/dev/null)"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "后端退出码 ${rc}（契约要求 exit 0）: $*"
  "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); assert isinstance(d, dict) and "ok" in d' "$out" 2>/dev/null \
    || fail "stdout 不是合法 JSON 信封: ${out:0:200}"
  printf '%s' "$out"
}

# expect <case> <json> <python bool expr over d>
expect() {
  local ok
  ok="$(json_get "$2" "bool($3)")" || fail "$1: 断言求值出错 $3"
  [ "$ok" = "True" ] || fail "$1: 断言不成立 [$3] ← ${2:0:300}"
}
HAS_ZH='any("一" <= c <= "鿿" for c in'

# (1) 不存在的文件：单独 → 整体 ok:false；混在有效文件里 → skipped_missing，其他照常
J="$(run_json gui-run --op clean --files "$WORK/不存在.docx")"
expect c1-only "$J" "d['ok'] is False and $HAS_ZH d['error'])"
J="$(run_json gui-run --op clean --files "$WORK/不存在.md" "$MD")"
expect c1-mixed "$J" "d['ok'] and d.get('skipped_missing')==['不存在.md'] and d['succeeded']==1"
CASES+=('{"id":"missing_file","ok":true,"note":"单独→ok:false 中文提示；混批→skipped_missing，其余成功"}')

# (2) 损坏 docx 与有效 docx 同批：坏的逐文件失败，好的成功（部分失败隔离）
J="$(run_json gui-run --op clean --files "$BAD" "$DOCX")"
expect c2 "$J" "d['ok'] and d['total']==2 and d['succeeded']==1"
expect c2-bad "$J" "[r for r in d['results'] if r['name']=='损坏.docx'][0]['ok'] is False"
expect c2-msg "$J" "$HAS_ZH [r for r in d['results'] if r['name']=='损坏.docx'][0]['message'])"
expect c2-good "$J" "(lambda r: r['ok'] and r['outputs'] and all(__import__('os').path.isfile(o) for o in r['outputs']))([r for r in d['results'] if r['name']=='活动说明.docx'][0])"
CASES+=('{"id":"corrupt_docx_isolation","ok":true,"note":"坏 docx 单行失败，同批有效 docx 产出成功"}')

# (3) 不支持的扩展名 / 未知操作
J="$(run_json gui-run --op stripchrome --files "$MD")"
expect c3-ext "$J" "d['succeeded']==0 and d['results'][0]['ok'] is False and '不支持' in d['results'][0]['message']"
J="$(run_json gui-run --op convert --to word --files "$JPG")"
expect c3-jpg "$J" "d['succeeded']==0 and '不支持' in d['results'][0]['message']"
J="$(run_json gui-run --op 不存在的操作 --files "$MD")"
expect c3-op "$J" "d['ok'] is False and '未知操作' in d['error']"
CASES+=('{"id":"unsupported","ok":true,"note":"md→清页眉页脚、jpg→Word 逐文件「该操作不支持」；未知操作 ok:false"}')

# (4) convert 不给 --to
J="$(run_json gui-run --op convert --files "$MD")"
expect c4 "$J" "d['ok'] is False and '--to' in d['error'] and $HAS_ZH d['error'])"
CASES+=('{"id":"convert_without_target","ok":true}')

# (5a) 输出目录只读 → ok:false 且不产生任何文件
RO="$WORK/ro"; mkdir -p "$RO"; chmod 555 "$RO"
set +e; J="$(DOCKIT_OUTPUT_DIR="$RO" backend gui-run --op clean --files "$MD")"; rc=$?; set -e
chmod 755 "$RO"
[ "$rc" -eq 0 ] || fail "只读输出目录时后端退出码 $rc"
expect c5-ro "$J" "d['ok'] is False and $HAS_ZH d['error'])"
[ -z "$(ls -A "$RO")" ] || fail "c5-ro: 只读目录内出现了文件"
# (5b) 同一操作重复跑 + 同名输入同批：每次新工作目录，旧产出不被覆盖，同名自动加 -2
J1="$(run_json gui-run --op convert --to word --files "$MD")"
expect c5-first "$J1" "d['succeeded']==1"
FIRST_OUT="$(json_get "$J1" "d['results'][0]['outputs'][0]")"
FIRST_HASH="$(shasum -a 256 "$FIRST_OUT")"
mkdir -p "$WORK/in2"; cp "$MD" "$WORK/in2/"
J2="$(run_json gui-run --op convert --to word --files "$MD" "$WORK/in2/读书会流程.md")"
expect c5-dup "$J2" "d['succeeded']==2 and len({r['outputs'][0] for r in d['results']})==2"
expect c5-new "$J2" "all(o != '$FIRST_OUT' for r in d['results'] for o in r['outputs'])"
[ "$(shasum -a 256 "$FIRST_OUT")" = "$FIRST_HASH" ] || fail "c5: 第一次产出被覆盖"
CASES+=('{"id":"readonly_output_and_collision","ok":true,"note":"只读目录 ok:false 无残留；重跑进新工作目录，同名输入加 -2，旧产出 sha256 不变"}')

# (6) 恢复：失败之后同一操作在好输入上成功，原件字节不变
J="$(run_json gui-run --op clean --files "$DOCX" "$MD")"
expect c6 "$J" "d['ok'] and d['succeeded']==2 and all(r['input'].startswith('$IN') or r['input'].endswith(r['name']) for r in d['results'])"
AFTER_HASH="$(hash_inputs)"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "c6: 输入原件在处理后发生变化"
CASES+=('{"id":"recovery_and_originals","ok":true,"note":"失败后重跑成功；全部 8 个输入 sha256 与开始前一致"}')

SECS=$(( $(date +%s) - START ))
SUMMARY="失败与恢复 6 类用例通过（缺失/损坏隔离/不支持/缺 --to/只读与重名/重跑恢复），原件未改，${SECS}s"
accept_detail true "$SUMMARY" "{\"seconds\": $SECS, \"cases\": [$(IFS=,; echo "${CASES[*]}")]}"
echo "PASS recovery: $SUMMARY"
