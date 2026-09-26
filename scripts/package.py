#!/usr/bin/env python3
"""Package, sign and manifest the compiled app. No installation.

    package.py                 build/DocKit.app + dist/DocKit-v<version>-arm64.zip (release layout)
    package.py --out DIR       app, archive and manifest all go to DIR (trial builds; dist/ untouched)
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, help="write app, archive and manifest here instead of build/ and dist/")
out = parser.parse_args().out
out = (ROOT / out).resolve() if out and not out.is_absolute() else out
version = (ROOT / "VERSION").read_text().strip()
app = (out or ROOT / "build") / "DocKit.app"
if app.exists(): shutil.rmtree(app)
resources = app / "Contents/Resources"
(app / "Contents/MacOS").mkdir(parents=True)
resources.mkdir()
executable = app / "Contents/MacOS/DocTools"
shutil.copy2(ROOT / "build/DocTools", executable)
# Release strip: drop the executable's local symbols (build/DocTools keeps them); exported and
# undefined symbols stay, so nothing changes at run time. swiftc runs without -g, so there is no
# debug map to remove. The bundled runtime is stripped by slim-runtime.py; everything is signed below.
subprocess.run(["strip", "-x", str(executable)], check=True)
shutil.copy2(ROOT / "icon/AppIcon.icns", resources / "AppIcon.icns")
shutil.copytree(ROOT / "backend", resources / "backend", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
shutil.copytree(ROOT / "build/runtime/python", resources / "python", symlinks=True)
for name in ("LICENSE", "THIRD-PARTY-NOTICES.md"): shutil.copy2(ROOT / name, resources / name)
# Ship only what the operations run: see scripts/slim-runtime.py for every rule and its guard.
subprocess.run([sys.executable, str(ROOT / "scripts/slim-runtime.py"), str(resources)], check=True)
shutil.copytree(ROOT / "third-party", resources / "licenses")
info = plistlib.loads((ROOT / "Info.plist").read_bytes())
info.update(CFBundleName="DocKit", CFBundleDisplayName="DocKit", CFBundleShortVersionString=version,
            CFBundleVersion=subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=ROOT, text=True).strip(),
            NSHumanReadableCopyright="DocKit · MIT License")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
magics = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}
def local_symbols(path):
    # nm's type letter is column 18 (symbol names may contain spaces); t/d/b/s are local symbols.
    listing = subprocess.run(["nm", "-a", str(path)], capture_output=True, text=True, check=True).stdout
    return sum(1 for line in listing.splitlines() if len(line) > 18 and line[16] == " " and line[18] == " " and line[17] in "tdbs")
unstripped = [f"MacOS/DocTools: {n}" for n in [local_symbols(executable)] if n]
for path in resources.rglob("*"):
    if not path.is_file() or path.is_symlink(): continue
    with path.open("rb") as handle: magic = handle.read(4)
    if magic in magics:
        if (n := local_symbols(path)): unstripped.append(f"{path.relative_to(app / 'Contents')}: {n}")
        subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
if unstripped: sys.exit("package: local symbols left in the release app (fail-closed):\n  " + "\n  ".join(unstripped))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
dist = out or ROOT / "dist"
dist.mkdir(parents=True, exist_ok=True)
archive = dist / f"DocKit-v{version}-arm64.zip"
if archive.exists(): archive.unlink()
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
manifest = {"product": "DocKit", "version": version, "tag": "v"+version, "bundle_id": info["CFBundleIdentifier"],
            "build": info["CFBundleVersion"],
            "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT, text=True).strip()),
            "source_executable_sha256": hashlib.sha256((app / "Contents/MacOS/DocTools").read_bytes()).hexdigest(),
            "filename": archive.name, "bytes": archive.stat().st_size,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "arch": "arm64", "minimum_macos": "15.0",
            "signing": "ad-hoc; not notarized", "runtime": "bundled CPython 3.12.13",
            "download_url": f"https://github.com/zengtianli/doc-tools/releases/download/v{version}/{archive.name}"}
(dist / "release-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")
print(json.dumps(manifest, ensure_ascii=False, indent=2))
