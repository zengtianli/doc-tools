#!/usr/bin/env python3
"""Run real bundled document operations after relocation with no ambient dependencies."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
original_app = ROOT / "build/DocKit.app"
with tempfile.TemporaryDirectory(prefix="dockit-relocation-") as td:
    root=Path(td);app=root/"Renamed application/DocKit.app"
    shutil.copytree(original_app,app,symlinks=True)
    resources=app/"Contents/Resources";python=resources/"python/bin/python3.12";backend=resources/"backend/doc_gui_backend.py"
    fixtures=root/"Fixtures";home=root/"Empty home";home.mkdir()
    env={"HOME":str(home),"PATH":"/usr/bin:/bin","PYTHONDONTWRITEBYTECODE":"1","PYTHONNOUSERSITE":"1","LANG":"en_US.UTF-8","DOCKIT_NO_OPEN":"1"}
    subprocess.run([str(python),"-B",str(ROOT/"scripts/make-demo.py"),str(fixtures)],env=env,check=True,capture_output=True)
    before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir() if p.is_file()}
    profile='(version 1)(allow default)(deny network*)'
    prefix=["/usr/bin/sandbox-exec","-p",profile,str(python),"-s","-B",str(backend)]
    def run(args):
        start=time.perf_counter()
        result=subprocess.run(prefix+args,env=env,cwd=home,check=True,capture_output=True,text=True,timeout=90)
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
    ]
    records=[]
    for op,args,names in cases:
        result,seconds=run(["gui-run","--op",op]+args+["--files"]+[str(fixtures/n) for n in names])
        assert result.get("ok") and result["succeeded"]==result["total"] and result["total"]>0, result
        assert all(Path(p).exists() for row in result["results"] for p in row["outputs"]), result
        records.append({"operation":op,"targets":args,"inputs":names,"seconds":seconds})
        if op=="quotes":
            output=next(Path(p) for p in result["results"][0]["outputs"] if p.endswith(".docx"))
            code="from docx import Document;import sys;d=Document(sys.argv[1]);t=''.join(p.text for p in d.paragraphs);assert '“读书与日常”' in t;assert '120 平方米' in t;assert 'https://example.com/signup?day=1' in t;assert d.sections[0].header.paragraphs[0].text=='星河读书会 \\\"虚构演示\\\"'"
            code=code.replace('\\\"','"')
            subprocess.run([str(python),"-s","-B","-c",code,str(output)],env=env,check=True)
    partial,_=run(["gui-run","--op","quotes","--files",str(fixtures/"活动说明.docx"),str(fixtures/"不支持的图片.jpg")])
    assert partial["succeeded"]==1 and partial["total"]==2,partial
    invalid,_=run(["gui-run","--op","quotes","--opt","made_up=1","--files",str(fixtures/"活动说明.docx")])
    assert invalid["ok"] is False,invalid
    after={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir() if p.is_file()}
    assert before==after,"Original inputs changed"
    subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
    report={"version":(ROOT/"VERSION").read_text().strip(),"network":"denied by sandbox-exec", "ambient_home":"empty", "path":"/usr/bin:/bin", "relocation":"renamed application directory", "originals_unchanged":True,"cases":records,"partial_success":True,"invalid_options_rejected":True}
    (ROOT/"build/package-verification.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False,indent=2))
