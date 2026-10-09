#!/usr/bin/env python3
"""Package, sign and manifest the compiled app. No installation.

    package.py                 build/DocKit.app + dist/DocKit-v<version>-arm64.zip (release layout)
    package.py --out DIR       app, archive and manifest all go to DIR (trial builds; dist/ untouched)

Signing. A Mac that holds a Developer ID Application certificate signs the app and every Mach-O file of
the bundled runtime with it, with the hardened runtime and a secure timestamp: the distribution build,
ready for scripts/notarize.py. A Mac without one signs ad-hoc: a local trial that Gatekeeper rejects
elsewhere, and that scripts/install.py and `publish.py --upload` refuse. DOCKIT_SIGN_IDENTITY names the
certificate when several exist; DOCKIT_SIGN_IDENTITY=- forces ad-hoc. Signing with a certificate needs
the login session's keychain (over plain SSH codesign answers errSecInternalComponent).
"""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import plistlib
import re
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
def signing_identity():
    """The Developer ID Application certificate of this Mac (distribution build), or "-" (ad-hoc, local trial)."""
    chosen = os.environ.get("DOCKIT_SIGN_IDENTITY")
    if chosen: return chosen
    listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    found = sorted(set(re.findall(r'"(Developer ID Application:[^"]+)"', listing)))
    if len(found) > 1: sys.exit("package: several Developer ID Application certificates; set DOCKIT_SIGN_IDENTITY to one of them.")
    return found[0] if found else "-"
identity = signing_identity()
distribution = identity != "-"
# Notarization requires the hardened runtime and a secure timestamp on every executable and library.
sign = ["codesign", "--force", "--sign", identity] + (["--options", "runtime", "--timestamp"] if distribution else [])
def codesign(path):
    done = subprocess.run(sign + [str(path)], capture_output=True, text=True)
    if done.returncode:
        hint = "\n  (errSecInternalComponent: the keychain is locked for this session; sign from the login session)" if "errSecInternalComponent" in done.stderr else ""
        sys.exit(f"package: codesign failed for {path}:\n  {done.stderr.strip()}{hint}")
unstripped = [f"MacOS/DocTools: {n}" for n in [local_symbols(executable)] if n]
nested = []
for path in resources.rglob("*"):
    if not path.is_file() or path.is_symlink(): continue
    with path.open("rb") as handle: magic = handle.read(4)
    if magic in magics:
        if (n := local_symbols(path)): unstripped.append(f"{path.relative_to(app / 'Contents')}: {n}")
        nested.append(path)
if unstripped: sys.exit("package: local symbols left in the release app (fail-closed):\n  " + "\n  ".join(unstripped))
# The runtime's Mach-O files are independent of each other; the app is sealed last, over their signatures.
with ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(codesign, nested))
codesign(app)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
if distribution:
    # Fail closed: every Mach-O in the bundle carries this certificate's team, a secure timestamp, and the hardened runtime.
    team = re.search(r"\(([A-Z0-9]{10})\)\s*$", identity)
    for path in [executable] + nested:
        detail = subprocess.run(["codesign", "-dvv", str(path)], capture_output=True, text=True).stderr
        missing = [what for what, ok in (("Developer ID authority", "Authority=Developer ID Application" in detail),
                                         ("team", not team or f"TeamIdentifier={team.group(1)}" in detail),
                                         ("secure timestamp", "Timestamp=" in detail),
                                         ("hardened runtime", re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", detail) is not None)) if not ok]
        if missing: sys.exit(f"package: {path.relative_to(app)} lacks {', '.join(missing)} (fail-closed)")
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
            "signing": f"{identity}; hardened runtime; not yet notarized (run scripts/notarize.py)" if distribution else "ad-hoc; not notarized; local trial only",
            "signed_files": len(nested) + 1, "runtime": "bundled CPython 3.12.13",
            "download_url": f"https://github.com/zengtianli/doc-tools/releases/download/v{version}/{archive.name}"}
(dist / "release-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")
print(json.dumps(manifest, ensure_ascii=False, indent=2))
