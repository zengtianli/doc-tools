#!/usr/bin/env python3
"""Prepare an isolated, relocatable CPython runtime from uv's managed distribution."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "build/runtime/python"
VERSION = "3.12.13"
lock = ROOT / "backend/requirements.lock"
fingerprint = hashlib.sha256(lock.read_bytes()).hexdigest()
stamp = DEST / "dockit-runtime.json"
if stamp.exists() and json.loads(stamp.read_text()).get("requirements_sha256") == fingerprint:
    print("Python runtime already matches the dependency lock.")
    raise SystemExit(0)
uv = shutil.which("uv")
if not uv: raise SystemExit("Build dependency missing: install uv from https://docs.astral.sh/uv/getting-started/installation/")
found = subprocess.run([uv, "python", "find", "--managed-python", VERSION], text=True, capture_output=True)
if found.returncode:
    subprocess.run([uv, "python", "install", VERSION], check=True)
    found = subprocess.run([uv, "python", "find", "--managed-python", VERSION], text=True, capture_output=True, check=True)
source = Path(found.stdout.strip()).resolve().parents[1]
DEST.parent.mkdir(parents=True, exist_ok=True)
if DEST.exists(): shutil.rmtree(DEST)
shutil.copytree(source, DEST, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
site = DEST / "lib/python3.12/site-packages"
shutil.rmtree(site)
site.mkdir()
python = DEST / "bin/python3.12"
subprocess.run([uv, "pip", "install", "--python", str(python), "--target", str(site), "--require-hashes", "--only-binary", ":all:", "-r", str(lock)], check=True)
subprocess.run([str(python), "-I", "-B", "-c", "import docx, openpyxl, pptx, pandas, xlrd, markitdown"], check=True)
for item in (DEST / "bin").iterdir():
    if item.name not in ("python", "python3", "python3.12") and (item.is_file() or item.is_symlink()): item.unlink()
stamp.write_text(json.dumps({"python": VERSION, "source": "uv managed CPython / python-build-standalone", "requirements_sha256": fingerprint}, indent=2) + "\n")
print("Prepared portable CPython " + VERSION)
