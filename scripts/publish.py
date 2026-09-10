#!/usr/bin/env python3
"""Prepare a reviewable release, or upload its verified assets when requested."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument("--upload",action="store_true");a=ap.parse_args()
def run(args,**kw): return subprocess.run(args,cwd=ROOT,check=True,**kw)
run(["bash","build.sh"])
run(["python3","scripts/verify-package.py"])
run(["bash","scripts/check-ui-state.sh"])
manifest=json.loads((ROOT/"dist/release-manifest.json").read_text())
run(["python3","scripts/build-site.py"])
if a.upload:
    dirty=subprocess.check_output(["git","status","--porcelain"],cwd=ROOT,text=True).strip()
    if dirty: raise SystemExit("Commit and push the reviewed changes before uploading a release.")
    head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip()
    branch=subprocess.check_output(["git","branch","--show-current"],cwd=ROOT,text=True).strip()
    remote=subprocess.check_output(["git","ls-remote","origin","refs/heads/"+branch],cwd=ROOT,text=True).split()
    if not remote or remote[0]!=head: raise SystemExit("Push the reviewed commit before uploading its release.")
    existing=subprocess.run(["gh","release","view",manifest["tag"],"--repo","zengtianli/doc-tools"],cwd=ROOT,capture_output=True)
    if existing.returncode==0: raise SystemExit("This release already exists. Inspect its assets before retrying; no overwrite performed.")
    notes=ROOT/"build/release-notes.md"
    notes.write_text(f'DocKit {manifest["version"]}: 内置文档运行环境，支持本地离线处理；原件保留、每次任务独立输出；规则与范围可勾选。\n\nmacOS 15+，Apple Silicon。安装教程：https://app-mac-doctools.tianli.cyou/#install\n\nSHA-256: `{manifest["sha256"]}`\n')
    run(["gh","release","create",manifest["tag"],str(ROOT/"dist"/manifest["filename"]),str(ROOT/"dist/release-manifest.json"),"--repo","zengtianli/doc-tools","--target",head,"--title","DocKit "+manifest["version"],"--notes-file",str(notes)])
    run(["gh","release","view",manifest["tag"],"--repo","zengtianli/doc-tools","--json","url,assets"])
print("Website package ready for the existing apps-site deployment entry: build/site/")
