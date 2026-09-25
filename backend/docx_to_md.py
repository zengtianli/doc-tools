#!/usr/bin/env python3
"""docx → Markdown：直接运行 markitdown 自带的命令行（与 `python -m markitdown <文件> -o <输出>` 同一段代码）。

为什么包一层：markitdown 在导入时还会加载 magika（按文件内容猜类型，依赖 onnxruntime，
两者约占安装包 80 MB），每次转换都要加载一遍模型。打包时不带 magika（scripts/slim-runtime.py），
这里放一个轻量的替身，只回答 markitdown 选转换器时真正用到的那几类：

  · 真 docx（zip 里有 word/document.xml）→ docx，与扩展名一致，markitdown 只走 DOCX 转换器；
  · 扩展名是 .docx、内容其实是别的：zip 家族（pptx / xlsx / epub / 普通 zip）按包内目录识别，
    文本按内容分成 html / xml / csv / 纯文本，markitdown 先按 .docx 试、失败后按内容选转换器，
    与带 magika 的 v1.1.0 输出相同（例如 <h1>标题</h1><p>段落</p> → "# 标题\\n\\n段落"）；
  · 老 Excel（OLE 容器里有 Workbook/Book 流）→ xls，markitdown 用 xlrd 转表格；
  · 认不出的（空文件、截断的 zip、老 .doc/.ppt、图片等二进制）→ 不给猜测，
    markitdown 只按扩展名试 DOCX 转换器，照常报错。

markitdown 只在猜测状态为 "ok" 时才采用猜测。环境里装了 magika（例如开发时用 uv 跑）就照常用真的。
"""
import codecs
import importlib.util
import re
import sys
import types
import zipfile

_KINDS = {  # label -> (mime_type, extensions, is_text)，取值与 magika 的内容类型表一致
    "docx": ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", ["docx", "docm"], False),
    "pptx": ("application/vnd.openxmlformats-officedocument.presentationml.presentation", ["pptx", "pptm"], False),
    "xlsx": ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ["xlsx", "xlsm"], False),
    "epub": ("application/epub+zip", ["epub"], False),
    "zip": ("application/zip", ["zip"], False),
    "xls": ("application/vnd.ms-excel", ["xls"], False),
    "html": ("text/html", ["html", "htm", "xhtml", "xht"], True),
    "xml": ("text/xml", ["xml"], True),
    "csv": ("text/csv", ["csv"], True),
    "txt": ("text/plain", ["txt"], True),
}
_HTML = re.compile(r"<(?:html|head|body)[\s>]")
_HEAD = 4096


def _zip_kind(stream) -> str | None:
    with zipfile.ZipFile(stream) as z:
        names = set(z.namelist())
        if "mimetype" in names:  # ODF / EPUB 容器自报类型
            return "epub" if z.read("mimetype").strip() == b"application/epub+zip" else None
    for part, kind in (("word/document.xml", "docx"), ("ppt/presentation.xml", "pptx"), ("xl/workbook.xml", "xlsx")):
        if part in names:
            return kind
    return "zip"


def _ole_kind(stream) -> str | None:
    """OLE 复合文档里只有老 Excel 有 markitdown 能用的转换器；找 Workbook/Book 流的目录项
    （128 字节对齐，偏移 64 是名字字节数，66 是对象类型，2 = 流）。"""
    data = stream.read(64 << 20)
    for name in ("Workbook", "Book"):
        entry = name.encode("utf-16-le") + b"\0\0"
        at = data.find(entry, 512)
        while at != -1:
            if at % 128 == 0 and data[at + 64:at + 66] == len(entry).to_bytes(2, "little") and data[at + 66:at + 67] == b"\x02":
                return "xls"
            at = data.find(entry, at + 1)
    return None


def _text(head: bytes) -> str | None:
    """文本内容返回解码后的开头，二进制返回 None。"""
    if head.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return head.decode("utf-16", "replace")
    if b"\x00" in head:
        return None
    try:  # final=False：开头 4 KB 可能正好截在一个多字节字符中间
        return codecs.getincrementaldecoder("utf-8-sig")().decode(head, final=False)
    except UnicodeDecodeError:
        import charset_normalizer  # markitdown 自身的依赖

        best = charset_normalizer.from_bytes(head).best()
        return str(best) if best is not None else None


def _text_kind(text: str, truncated: bool) -> str:
    lead = text.lstrip().lower()
    if lead.startswith(("<!doctype html", "<html")) or _HTML.search(lead[:2048]):
        return "html"
    if lead.startswith(("<?xml", "<rss", "<feed")):
        return "xml"
    lines = [line for line in text.splitlines()[:20] if line.strip()]
    if truncated and len(lines) > 1:
        lines = lines[:-1]  # 最后一行可能不完整
    commas = {line.count(",") for line in lines}
    if len(lines) >= 2 and len(commas) == 1 and min(commas) >= 1:
        return "csv"
    return "txt"


def identify(stream) -> str | None:
    """按内容判断类型；认不出返回 None。读完把流位置复原。"""
    start = stream.tell()
    try:
        head = stream.read(_HEAD)
        if not head:
            return None
        if head.startswith(b"PK"):
            stream.seek(start)
            return _zip_kind(stream) if zipfile.is_zipfile(stream) else None  # 截断的 zip 不猜
        if head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):  # OLE：老 .doc/.xls/.ppt
            stream.seek(start)
            return _ole_kind(stream)
        text = _text(head)
        return None if text is None else _text_kind(text, len(head) == _HEAD)
    except Exception:  # noqa: BLE001 — 猜不出就不猜，由 markitdown 按扩展名处理
        return None
    finally:
        stream.seek(start)


class _Magika:
    """markitdown 只调用 identify_stream，并只读 status 与 prediction.output 的这几个字段。"""

    def identify_stream(self, stream):
        label = identify(stream)
        if label is None:
            return types.SimpleNamespace(status="unavailable", prediction=None)
        mime_type, extensions, is_text = _KINDS[label]
        output = types.SimpleNamespace(label=label, mime_type=mime_type, extensions=extensions, is_text=is_text)
        return types.SimpleNamespace(status="ok", prediction=types.SimpleNamespace(output=output))


if importlib.util.find_spec("magika") is None:
    _stub = types.ModuleType("magika")
    _stub.Magika = _Magika
    _stub.DOCKIT_PLACEHOLDER = True
    sys.modules["magika"] = _stub

from markitdown.__main__ import main  # noqa: E402  占位必须先于 markitdown 导入

if __name__ == "__main__":
    main()
