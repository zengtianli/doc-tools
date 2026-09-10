#!/usr/bin/env python3
"""Prepare a reviewable release, or upload its verified assets when requested."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser()
mode=ap.add_mutually_exclusive_group()
mode.add_argument("--upload",action="store_true",help="Verify and upload the frozen dist archive without rebuilding")
mode.add_argument("--check-prepared",action="store_true",help="Verify the frozen archive and site without rebuilding or uploading")
a=ap.parse_args()
def run(args,**kw): return subprocess.run(args,cwd=ROOT,check=True,**kw)
if not (a.upload or a.check_prepared):
    run(["bash","build.sh"])
    run(["python3","scripts/verify-package.py"])
    run(["bash","scripts/check-ui-state.sh"])
manifest=json.loads((ROOT/"dist/release-manifest.json").read_text())
archive=ROOT/"dist"/manifest["filename"]
if hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest["sha256"]:
    raise SystemExit("Prepared release archive hash mismatch; no upload performed.")
if archive.stat().st_size!=manifest["bytes"]:
    raise SystemExit("Prepared release archive size mismatch; no upload performed.")
# Upload validates the frozen archive itself; it never regenerates the binary
# after recordings and screenshots have been accepted.
with tempfile.TemporaryDirectory(prefix="dockit-release-check-") as temporary:
    run(["ditto","-x","-k",str(archive),temporary])
    app=Path(temporary)/"DocKit.app"
    run(["codesign","--verify","--deep","--strict",str(app)])
    info=plistlib.loads((app/"Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"]!=manifest["version"] or
        info["CFBundleVersion"]!=manifest["build"] or
        info["CFBundleIdentifier"]!=manifest["bundle_id"]):
        raise SystemExit("Prepared archive identity does not match its manifest.")
    executable=app/"Contents/MacOS"/info["CFBundleExecutable"]
    if hashlib.sha256(executable.read_bytes()).hexdigest()!=manifest["source_executable_sha256"]:
        raise SystemExit("Prepared archive executable does not match its recorded source hash.")
run(["python3","scripts/build-site.py"])
if a.upload:
    dirty=subprocess.check_output(["git","status","--porcelain"],cwd=ROOT,text=True).strip()
    if dirty: raise SystemExit("Commit and push the reviewed changes before uploading a release.")
    head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip()
    branch=subprocess.check_output(["git","branch","--show-current"],cwd=ROOT,text=True).strip()
    remote=subprocess.check_output(["git","ls-remote","origin","refs/heads/"+branch],cwd=ROOT,text=True).split()
    if not remote or remote[0]!=head: raise SystemExit("Push the reviewed commit before uploading its release.")
    source=manifest["source_commit"]
    if manifest.get("source_dirty"):
        raise SystemExit("This binary was built from uncommitted sources; prepare a traceable release first.")
    run(["git","merge-base","--is-ancestor",source,head])
    existing=subprocess.run(["gh","release","view",manifest["tag"],"--repo","zengtianli/doc-tools"],cwd=ROOT,capture_output=True)
    if existing.returncode==0: raise SystemExit("This release already exists. Inspect its assets before retrying; no overwrite performed.")
    notes=ROOT/"build/release-notes.md"
    notes.write_text(f'DocKit {manifest["version"]} (build {manifest["build"]}): 内置文档运行环境，支持本地离线处理；原件保留、每次任务独立输出；规则与范围可勾选。\n\nmacOS 15+，Apple Silicon。安装教程：https://app-mac-doctools.tianli.cyou/#install\n\nBinary source commit: `{source}`\n\nSHA-256: `{manifest["sha256"]}`\n')
    run(["gh","release","create",manifest["tag"],str(archive),str(ROOT/"dist/release-manifest.json"),"--repo","zengtianli/doc-tools","--target",source,"--title","DocKit "+manifest["version"],"--notes-file",str(notes)])
    run(["gh","release","view",manifest["tag"],"--repo","zengtianli/doc-tools","--json","url,assets"])
print("Website package ready for the existing apps-site deployment entry: build/site/")
