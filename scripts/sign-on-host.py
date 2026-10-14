#!/usr/bin/env python3
"""Send one frozen product archive to the existing login-session signer; never compile or install there."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = (ROOT / args.out).resolve()
    if not out.is_relative_to(ROOT / "build"):
        parser.error("Signing continuation must stay in this product's build directory")
    manifest = json.loads((out / "release-manifest.json").read_text())
    archive = out / manifest["filename"]
    if archive.name != manifest["filename"] or sha(archive) != manifest["sha256"]:
        raise ValueError("Frozen archive does not match its manifest")
    name = "dockit-basics-sign-" + str(os.getpid())
    remote = "/Users/tianli/Library/Caches/mac-pair/login-run/" + name
    subprocess.run(["ssh", "-o", "BatchMode=yes", args.host, "mkdir -p " + shlex.quote(remote + "/stage")], check=True, timeout=60)
    subprocess.run(["scp", "-q", str(archive), str(out / "release-manifest.json"), str(ROOT / "scripts/package.py"),
                    args.host + ":" + remote + "/stage/"], check=True, timeout=120)
    script = out / "sign-login.sh"
    script.write_text("#!/bin/zsh\nset -euo pipefail\ncd " + shlex.quote(remote + "/stage") + "\n"
                      + "test \"$(/usr/bin/shasum -a 256 " + shlex.quote(archive.name) + " | /usr/bin/awk '{print $1}')\" = " + shlex.quote(manifest["sha256"]) + "\n"
                      + "test \"$(/usr/bin/shasum -a 256 package.py | /usr/bin/awk '{print $1}')\" = " + shlex.quote(sha(ROOT / "scripts/package.py")) + "\n"
                      + "/usr/bin/ditto -x -k " + shlex.quote(archive.name) + " .\n"
                      + "PYTHONDONTWRITEBYTECODE=1 python3 package.py --sign-existing --out " + shlex.quote(remote + "/stage") + "\n")
    login = Path.home() / "Dev/tools/cc-home/skills/macmini/scripts/login_run.py"
    subprocess.run(["python3", str(login), "--host", args.host, "--name", name, "--script", str(script),
                    "--timeout", "300", "--tail", "12"], check=True, timeout=360)
    with tempfile.TemporaryDirectory(prefix="signed-return-", dir=out) as tmp:
        returned = Path(tmp)
        subprocess.run(["scp", "-q", args.host + ":" + remote + "/stage/" + archive.name,
                        args.host + ":" + remote + "/stage/release-manifest.json", str(returned)], check=True, timeout=120)
        signed = json.loads((returned / "release-manifest.json").read_text())
        invariant = ("version", "build", "bundle_id", "source_commit", "source_dirty", "filename")
        if (any(signed[key] != manifest[key] for key in invariant) or sha(returned / archive.name) != signed["sha256"]
            or (returned / archive.name).stat().st_size != signed["bytes"]):
            raise ValueError("Signed return identity/source/archive mismatch")
        unpacked = returned / "unpacked"
        subprocess.run(["ditto", "-x", "-k", str(returned / archive.name), str(unpacked)], check=True)
        app = unpacked / "DocKit.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if ((info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"])
            != (signed["bundle_id"], signed["version"], signed["build"])
            or sha(app / "Contents/MacOS/DocTools") != signed["source_executable_sha256"]):
            raise ValueError("Signed bundle does not match returned manifest")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        shutil.rmtree(out / "DocKit.app")
        shutil.move(str(app), out / "DocKit.app")
        shutil.copy2(returned / archive.name, archive)
        shutil.copy2(returned / "release-manifest.json", out / "release-manifest.json")
    print("Frozen package signed in the certificate host's login session; no notarization, installation or publication there.")


if __name__ == "__main__":
    main()
