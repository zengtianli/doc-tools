#!/usr/bin/env python3
"""
文档/数据 统一调度器 —— 按文件后缀自动 route 到现有引擎(零重写,纯路由层)。

设计:命令只表达"动词",格式让本脚本运行时认。和 content-router 同一模式。
所有底层引擎(md_tools/pptx_tools/docx_*/data/convert 等)一个不改,subprocess 调用。

用法:
  doc_dispatch.py clean    <files...>                 规范化(docx 文本修复 / md format / pptx 全套)
  doc_dispatch.py convert  --to {md,word,xlsx,csv,txt} <files...>   转换(源自动认;老 .doc 经 textutil 升级)
  doc_dispatch.py merge    <files...>                 合并(md/txt→csv/xlsx)
  doc_dispatch.py split    <files...>                 拆分(md 按标题 / xlsx 按 sheet)
  doc_dispatch.py view     <files...>                 预览(md → HTML 浏览器)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

DOC = Path(__file__).resolve().parent            # 后端目录(所有引擎平铺同目录)
DATA = DOC                                       # 数据引擎与文档引擎同目录
PY = sys.executable                              # 当前解释器(uv 环境的 python)

# 兜底 PYTHONPATH:子进程引擎的本地模块(display/file_ops/finder 等)全在本目录,统一补齐。
_LIBS = [str(DOC)]
_ENV = {**os.environ, "PYTHONPATH": os.pathsep.join(_LIBS + [os.environ.get("PYTHONPATH", "")])}

GREEN, YELLOW, RED, DIM, RST = "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"


def _ext(f: str) -> str:
    return Path(f).suffix.lower().lstrip(".")


def _run(cmd: list[str], label: str) -> int:
    print(f"{DIM}  ↳ {label}{RST}")
    try:
        return subprocess.run(cmd, env=_ENV).returncode
    except FileNotFoundError:
        if cmd and cmd[0] == "uvx":
            print(f"{RED}✖ 未找到 uvx:docx → Markdown 依赖 uv(安装: brew install uv){RST}")
        else:
            print(f"{RED}✖ 命令不存在: {cmd[0] if cmd else '?'}{RST}")
        return 1


def _py(engine: str, *args: str) -> list[str]:
    return [PY, str(DOC / engine), *args]


def _data(engine: str, *args: str) -> list[str]:
    return [PY, str(DATA / engine), *args]


def warn(msg: str) -> None:
    print(f"{YELLOW}  ⚠ {msg}{RST}")


def _doc_to_docx(f: str) -> str | None:
    """老 .doc → .docx。优先 soffice(产完整 docx 含 styles.xml,下游套模板等引擎都吃),
    没装 LibreOffice 才 textutil 兜底(极简 docx,缺 styles.xml,套模板线会挂)。
    成功返回产出路径,失败返回 None。"""
    p = Path(f)
    out = p.with_suffix(".docx")
    soffice = shutil.which("soffice") or "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    if Path(soffice).exists():
        cmd = [soffice, "--headless",
               "-env:UserInstallation=file:///tmp/lo_profile_doc_dispatch",
               "--convert-to", "docx", "--outdir", str(p.parent), str(p)]
        if _run(cmd, "老 doc → docx(soffice)") == 0 and out.exists():
            return str(out)
    if _run(["textutil", "-convert", "docx", str(p), "-output", str(out)], "老 doc → docx(textutil 兜底)"):
        return None
    return str(out) if out.exists() else None


# ───────────────────────────────────────────── 路由表

def route_clean(f: str) -> tuple[list[str], str] | None:
    e = _ext(f)
    if e == "docx":
        return _py("docx_text_formatter.py", f), "docx → 文本修复(引号/标点/单位)"
    if e == "md":
        return _py("md_tools.py", "format", f), "md → 格式标准化"
    if e in ("pptx",):
        return _py("pptx_tools.py", "all", f), "pptx → 字体+表格+文本 全套规范"
    if e in ("xlsx", "xlsm"):
        return _data("xlsx_lowercase.py", f), "xlsx → 英文小写整理"
    return None


def route_convert(f: str, target: str) -> tuple[list[str], str] | None:
    e = _ext(f)
    M = {
        ("pptx", "md"): (_py("pptx_to_md.py", f), "pptx → Markdown"),
        ("ppt", "md"): (_py("pptx_to_md.py", f), "ppt → Markdown"),
        ("md", "word"): (_py("md_docx_template.py", f), "md → Word(套模板)"),
        ("docx", "word"): (_py("docx_apply_template.py", f), "docx → 套模板重排"),
        ("csv", "xlsx"): (_data("convert.py", "xlsx-from-csv", f), "csv → Excel"),
        ("txt", "xlsx"): (_data("convert.py", "xlsx-from-txt", f), "txt → Excel"),
        ("xls", "xlsx"): (_data("convert.py", "xlsx-from-xls", f), "老 xls → xlsx"),
        ("txt", "csv"): (_data("convert.py", "csv-from-txt", f), "txt → CSV"),
        ("xlsx", "csv"): (_data("convert.py", "xlsx-to-csv", f), "Excel → CSV"),
        ("csv", "txt"): (_data("convert.py", "csv-to-txt", f), "CSV → txt"),
        ("xlsx", "txt"): (_data("convert.py", "xlsx-to-txt", f), "Excel → txt"),
    }
    # docx→md 走 markitdown(经 uvx 临时环境调用,无需预装)
    if e == "docx" and target == "md":
        out = str(Path(f).with_suffix(".md"))
        return ["uvx", "markitdown", f, "-o", out], "docx → Markdown(markitdown)"
    hit = M.get((e, target))
    return (hit[0], hit[1]) if hit else None


def route_merge(f: str) -> tuple[list[str], str] | None:
    e = _ext(f)
    if e == "md":
        return None, "md"     # md 走批量(下面特判:一次传所有)
    if e == "txt":
        return None, "txt"
    if e in ("xlsx", "xlsm"):
        return None, "xlsx"
    return None


def route_split(f: str) -> tuple[list[str], str] | None:
    e = _ext(f)
    if e == "md":
        return _py("md_tools.py", "split", f), "md → 按标题拆分"
    if e in ("xlsx", "xlsm"):
        return _data("xlsx_splitsheets.py", f), "xlsx → 按 sheet 拆分"
    return None


# ───────────────────────────────────────────── 动词实现

def _per_file(files: list[str], router, verb: str) -> int:
    rc = 0
    for f in files:
        if not Path(f).exists():
            warn(f"文件不存在,跳过: {f}")
            continue
        hit = router(f)
        if not hit:
            warn(f"{Path(f).name}: 没有「{verb}」对应的 {_ext(f) or '?'} 引擎,跳过")
            continue
        cmd, label = hit
        print(f"{GREEN}● {Path(f).name}{RST}")
        rc |= _run(cmd, label)
    return rc


def do_clean(files):  return _per_file(files, route_clean, "规范化")
def do_split(files):  return _per_file(files, route_split, "拆分")


def _word_textfix(out: Path) -> int:
    """convert→word 收尾:自动文本修复(引号/标点/单位),成品就地替换,不留中间文件。
    用户钦定:转出来的 docx 直接就是 text_format 好的,不用再手动跑一遍规范化。"""
    if not out.exists():
        warn(f"未找到转换产出 {out.name},跳过文本修复")
        return 1
    if _run(_py("docx_text_formatter.py", str(out)), "文本修复(引号/标点/单位)"):
        return 1
    fixed = out.with_name(f"{out.stem}_fixed{out.suffix}")
    if not fixed.exists():
        warn(f"文本修复未产出 {fixed.name}")
        return 1
    fixed.replace(out)
    print(f"{GREEN}  ✓ 成品(已文本修复) → {out.name}{RST}")
    return 0


def _word_output(f: str) -> Path:
    """convert→word 各引擎的默认产出路径。"""
    p = Path(f)
    if _ext(f) == "docx":
        return p.with_name(f"{p.stem}_styled.docx")   # docx_apply_template.py
    return p.with_suffix(".docx")                     # md_docx_template.py / soffice


def do_convert(files, target):
    aliases = {"markdown": "md", "docx": "word", "excel": "xlsx", "text": "txt"}
    target = aliases.get(target, target)
    if target not in ("md", "word", "xlsx", "csv", "txt"):
        print(f"{RED}✖ 未知目标格式: {target}(支持 md/word/xlsx/csv/txt){RST}")
        return 2
    rc = 0
    for f in files:
        if not Path(f).exists():
            warn(f"文件不存在,跳过: {f}"); continue
        # 老 .doc:textutil 直转(word/txt),或先升级成 docx 再走 docx 路由(md)
        if _ext(f) == "doc":
            if target == "txt":
                print(f"{GREEN}● {Path(f).name}{RST}")
                rc |= _run(["textutil", "-convert", "txt", f], "老 doc → txt(textutil)")
                continue
            if target in ("word", "md"):
                print(f"{GREEN}● {Path(f).name}{RST}")
                nf = _doc_to_docx(f)
                if nf is None:
                    rc |= 1; continue
                if target == "word":
                    rc |= _word_textfix(Path(nf))
                    continue
                f = nf  # md:继续按 docx → md 路由
            else:
                warn(f"{Path(f).name}: doc → {target} 这条转换没引擎(不支持的组合),跳过")
                continue
            hit = route_convert(f, target)
            if hit:
                rc |= _run(hit[0], hit[1] or f"→ {target}")
            continue
        hit = route_convert(f, target)
        if not hit:
            warn(f"{Path(f).name}: {_ext(f) or '?'} → {target} 这条转换没引擎(不支持的组合),跳过")
            continue
        cmd, label = hit
        print(f"{GREEN}● {Path(f).name}{RST}")
        r = _run(cmd, label or f"→ {target}")
        rc |= r
        if r == 0 and target == "word":
            rc |= _word_textfix(_word_output(f))
    return rc


def do_view(files):
    rc = 0
    for f in files:
        if _ext(f) != "md":
            warn(f"{Path(f).name}: 预览目前只支持 md,跳过"); continue
        print(f"{GREEN}● {Path(f).name}{RST}")
        rc |= _run(_py("md_tools.py", "to-html", f), "md → HTML 浏览器预览")
    return rc


def do_merge(files):
    """合并按类型分组:md→md_tools merge;txt→csv-merge-txt;xlsx→xlsx_merge_tables(需主/辅表参数)。"""
    groups: dict[str, list[str]] = {}
    for f in files:
        groups.setdefault(_ext(f), []).append(f)
    rc = 0
    for e, fs in groups.items():
        if e == "md":
            print(f"{GREEN}● 合并 {len(fs)} 个 md{RST}")
            rc |= _run(_py("md_tools.py", "merge", *fs), "md → 合并为一篇")
        elif e == "txt":
            print(f"{GREEN}● 合并 {len(fs)} 个 txt → CSV{RST}")
            rc |= _run(_data("convert.py", "csv-merge-txt", *fs), "txt 按列 → CSV")
        elif e in ("xlsx", "xlsm"):
            warn(f"xlsx 合并需指定主表/辅表/列映射,非纯多选;此版本未包含该引擎,跳过({len(fs)} 个)")
        else:
            warn(f".{e} 没有合并引擎,跳过({len(fs)} 个)")
    return rc


# ───────────────────────────────────────────── CLI

def main() -> int:
    ap = argparse.ArgumentParser(description="文档/数据统一调度器")
    sub = ap.add_subparsers(dest="verb", required=True)
    for v in ("clean", "merge", "split", "view"):
        p = sub.add_parser(v); p.add_argument("files", nargs="+")
    pc = sub.add_parser("convert")
    pc.add_argument("--to", required=True, dest="target")
    pc.add_argument("files", nargs="+")
    a = ap.parse_args()

    if a.verb == "clean":   return do_clean(a.files)
    if a.verb == "split":   return do_split(a.files)
    if a.verb == "view":    return do_view(a.files)
    if a.verb == "merge":   return do_merge(a.files)
    if a.verb == "convert": return do_convert(a.files, a.target)
    return 1


if __name__ == "__main__":
    sys.exit(main())
