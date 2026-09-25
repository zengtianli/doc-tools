#!/usr/bin/env python3
"""Run real bundled document operations after relocation with no ambient dependencies.

    verify-package.py [--app build/DocKit.app] [--report build/package-verification.json]
                      [--record-modules scripts/runtime-modules.txt]

--record-modules also writes every runtime .py file the operations imported (the bytecode list
used by scripts/slim-runtime.py). Regenerate it after changing the backend or requirements.lock.
Each operation must finish within 90 s; DOCKIT_VERIFY_TIMEOUT=<seconds> raises that on a slow machine.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument("--app", type=Path, default=ROOT / "build/DocKit.app")
ap.add_argument("--report", type=Path, default=ROOT / "build/package-verification.json")
ap.add_argument("--record-modules", type=Path)
cli = ap.parse_args()
original_app = cli.app.resolve()
TIMEOUT = float(os.environ.get("DOCKIT_VERIFY_TIMEOUT") or 90)
TRACE_HOOK = """import atexit, os, sys
def _dump():
    import json
    files = sorted({getattr(m, "__file__", None) or "" for m in list(sys.modules.values())} - {""})
    with open(os.path.join(os.environ["DOCKIT_TRACE_DIR"], "%d.json" % os.getpid()), "w") as fh:
        json.dump(files, fh)
atexit.register(_dump)
"""
with tempfile.TemporaryDirectory(prefix="dockit-relocation-") as td:
    root=Path(td);app=root/"Renamed application/DocKit.app"
    shutil.copytree(original_app,app,symlinks=True)
    resources=app/"Contents/Resources";python=resources/"python/bin/python3.12";backend=resources/"backend/doc_gui_backend.py"
    for item in (resources/"python").rglob("*"):
        if item.is_symlink(): assert item.resolve().is_relative_to((resources/"python").resolve()),item
        elif item.is_file() and item.stat().st_size<5000000:
            assert str(Path.home()).encode() not in item.read_bytes(),"Build-machine path remains in runtime metadata"
    fixtures=root/"Fixtures";home=root/"Empty home";home.mkdir()
    env={"HOME":str(home),"PATH":"/usr/bin:/bin","PYTHONDONTWRITEBYTECODE":"1","PYTHONNOUSERSITE":"1","LANG":"en_US.UTF-8","DOCKIT_NO_OPEN":"1"}
    subprocess.run([str(python),"-B",str(ROOT/"scripts/make-demo.py"),str(fixtures)],env=env,check=True,capture_output=True)
    (fixtures/"报名表.txt").write_text("活动\t人数\t面积\n读书会\t24\t120\n观影会\t18\t90\n",encoding="utf-8")
    (fixtures/"空格表.txt").write_text("姓名 年龄\n张三 30\n李四 25\n",encoding="utf-8")
    (fixtures/"报名表2.txt").write_text("活动\t人数\t面积\n游园会\t40\t300\n",encoding="utf-8")
    # .docx names whose content is really HTML / plain text (web-system exports): v1.1.0 converted these by content
    (fixtures/"网页导出.docx").write_text("<html><body><h1>标题</h1><p>段落</p></body></html>",encoding="utf-8")
    (fixtures/"纯文本.docx").write_text("纯文本 内容\nhello\n",encoding="utf-8")
    subprocess.run(["textutil","-convert","doc",str(fixtures/"活动说明.docx"),"-output",str(fixtures/"旧版说明.doc")],check=True)
    soffice=Path("/Applications/LibreOffice.app/Contents/MacOS/soffice")
    if soffice.exists():  # legacy .xls/.ppt inputs can only be made with LibreOffice
        for source,kind in (("活动统计.xlsx","xls"),("读书会介绍.pptx","ppt")):
            subprocess.run([str(soffice),"--headless","-env:UserInstallation=file://"+str(root/"lo-profile"),"--convert-to",kind,"--outdir",str(fixtures),str(fixtures/source)],check=True,capture_output=True)
    if cli.record_modules:
        hook=root/"trace-hook";hook.mkdir();(hook/"sitecustomize.py").write_text(TRACE_HOOK)
        trace=root/"trace";trace.mkdir()
        env.update(PYTHONPATH=str(hook),DOCKIT_TRACE_DIR=str(trace))
    before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir() if p.is_file()}
    profile='(version 1)(allow default)(deny network*)'
    # LibreOffice (optional, for legacy .ppt) talks to itself over a unix socket in /tmp; IP stays denied.
    lo_profile=profile+'(allow network* (local unix-socket (path-regex #"^/private/tmp/")))(allow network* (remote unix-socket (path-regex #"^/private/tmp/")))'
    def run(args,sandbox=profile,extra_env=None):
        start=time.perf_counter()
        command=["/usr/bin/sandbox-exec","-p",sandbox,str(python),"-s","-B",str(backend)]+args
        result=subprocess.run(command,env={**env,**(extra_env or {})},cwd=home,check=True,capture_output=True,text=True,timeout=TIMEOUT)
        payload=json.loads(result.stdout)
        return payload,round(time.perf_counter()-start,3)
    ops,_=run(["gui-ops"])
    assert len(ops["ops"])==9
    assert next(x for x in ops["ops"] if x["id"]=="clean")["options"]
    cases=[
        ("quotes",["--opt","scope.headers=0"], ["活动说明.docx"]),
        ("clean",[],["活动说明.docx"]),
        ("convert",["--to","md"],["活动说明.docx"]),
        ("convert",["--to","word"],["读书会流程.md"]),
        ("convert",["--to","xlsx"],["报名统计.csv"]),
        ("split",[],["读书会流程.md"]),
        ("split",[],["活动统计.xlsx"]),
        ("merge",[],["读书会流程.md","补充说明.md"]),
        ("fontunify",[],["读书会介绍.pptx"]),
        ("lowercase",[],["活动统计.xlsx"]),
        ("stripchrome",[],["活动说明.docx"]),
        ("view",[],["读书会流程.md"]),
        ("clean",[],["读书会介绍.pptx"]),
        ("convert",["--to","md"],["读书会介绍.pptx"]),
        ("clean",[],["读书会流程.md"]),
        ("quotes",[],["读书会流程.md"]),
        ("lowercase",[],["活动说明.docx"]),
        ("convert",["--to","word"],["活动说明.docx"]),
        ("convert",["--to","csv"],["活动统计.xlsx"]),
        ("convert",["--to","txt"],["活动统计.xlsx"]),
        ("convert",["--to","txt"],["报名统计.csv"]),
        ("convert",["--to","xlsx"],["报名表.txt"]),
        ("convert",["--to","csv"],["空格表.txt"]),
        ("convert",["--to","md"],["旧版说明.doc"]),
        ("convert",["--to","word"],["旧版说明.doc"]),
        ("convert",["--to","txt"],["旧版说明.doc"]),
        ("convert",["--to","md"],["网页导出.docx"]),
        ("convert",["--to","md"],["纯文本.docx"]),
        ("merge",[],["报名表.txt","报名表2.txt"]),
    ]
    if (fixtures/"活动统计.xls").exists(): cases.append(("convert",["--to","xlsx"],["活动统计.xls"]))
    if (fixtures/"读书会介绍.ppt").exists(): cases.append(("convert",["--to","md"],["读书会介绍.ppt"]))
    records=[]
    def produced(result,suffix):
        return next(Path(p) for p in result["results"][0]["outputs"] if p.endswith(suffix))
    for op,args,names in cases:
        legacy_ppt=names==["读书会介绍.ppt"]
        result,seconds=run(["gui-run","--op",op]+args+["--files"]+[str(fixtures/n) for n in names],sandbox=lo_profile if legacy_ppt else profile)
        assert result.get("ok") and result["succeeded"]==result["total"] and result["total"]>0, result
        assert all(Path(p).exists() for row in result["results"] for p in row["outputs"]), result
        records.append({"operation":op,"targets":args,"inputs":names,"seconds":seconds}|({"sandbox":"IP denied; /private/tmp unix sockets allowed for LibreOffice"} if legacy_ppt else {}))
        if op=="convert" and args==["--to","md"] and names[0].endswith((".ppt",".pptx")):
            text=produced(result,".md").read_text(encoding="utf-8")
            assert "## Slide 1" in text and "星河读书会" in text, text
        if names==["网页导出.docx"]:
            assert produced(result,".md").read_text(encoding="utf-8")=="# 标题\n\n段落", result
        if names==["纯文本.docx"]:
            assert produced(result,".md").read_text(encoding="utf-8")=="纯文本 内容\nhello\n", result
        if op=="merge" and names[0].endswith(".txt"):
            import csv
            rows=list(csv.reader(produced(result,"merged.csv").open(encoding="utf-8",newline="")))
            assert rows==[["活动\t人数\t面积"]*2,["读书会\t24\t120","游园会\t40\t300"],["观影会\t18\t90",""]], rows
        if op=="quotes" and names==["活动说明.docx"]:
            output=next(Path(p) for p in result["results"][0]["outputs"] if p.endswith(".docx"))
            code="from docx import Document;import sys;d=Document(sys.argv[1]);t=''.join(p.text for p in d.paragraphs);assert '“读书与日常”' in t;assert '120 平方米' in t;assert 'https://example.com/signup?day=1' in t;assert d.sections[0].header.paragraphs[0].text=='星河读书会 \\\"虚构演示\\\"'"
            code=code.replace('\\\"','"')
            subprocess.run([str(python),"-s","-B","-c",code,str(output)],env=env,check=True)
        if op=="convert" and args==["--to","md"] and names==["活动说明.docx"]:
            text=next(Path(p) for p in result["results"][0]["outputs"] if p.endswith(".md")).read_text(encoding="utf-8")
            assert "星河读书会 · 活动说明" in text and "| 签到 | 09:30 |" in text and "120 平方米" in text, text
    # Legacy .ppt without LibreOffice: an explicit failure that tells the user to save as .pptx, never a success.
    ppt=fixtures/"读书会介绍.ppt"
    if not ppt.exists(): ppt=root/"no-libreoffice"/"读书会介绍.ppt";ppt.parent.mkdir();ppt.write_bytes(b"\xd0\xcf\x11\xe0legacy")
    no_lo,_=run(["gui-run","--op","convert","--to","md","--files",str(ppt)],extra_env={"DOCKIT_SOFFICE":str(root/"no-libreoffice-installed")})
    row=no_lo["results"][0]
    assert no_lo["succeeded"]==0 and not row["ok"] and not row["outputs"] and "另存为 .pptx" in row["message"], no_lo
    partial,_=run(["gui-run","--op","quotes","--files",str(fixtures/"活动说明.docx"),str(fixtures/"不支持的图片.jpg")])
    assert partial["succeeded"]==1 and partial["total"]==2,partial
    invalid,_=run(["gui-run","--op","quotes","--opt","made_up=1","--files",str(fixtures/"活动说明.docx")])
    assert invalid["ok"] is False,invalid
    after={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir() if p.is_file()}
    assert before==after,"Original inputs changed"
    subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
    report={"version":(ROOT/"VERSION").read_text().strip(),"network":"denied by sandbox-exec", "ambient_home":"empty", "path":"/usr/bin:/bin", "relocation":"renamed application directory", "originals_unchanged":True,"cases":records,"partial_success":True,"invalid_options_rejected":True,"legacy_ppt_without_libreoffice":"explicit failure: "+row["message"]}
    if cli.record_modules:
        runtime=(resources/"python").resolve();found=set()
        for dump in trace.glob("*.json"):
            for name in json.loads(dump.read_text()):
                path=Path(name).resolve()
                if path.suffix==".py" and path.is_relative_to(runtime): found.add(str(path.relative_to(runtime)))
        header="# Runtime .py files imported by the operations in scripts/verify-package.py; bytecode is\n# precompiled for these by scripts/slim-runtime.py. Regenerate: verify-package.py --record-modules <this file>\n"
        cli.record_modules.write_text(header+"\n".join(sorted(found))+"\n")
        report["recorded_modules"]=len(found)
    cli.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False,indent=2))
