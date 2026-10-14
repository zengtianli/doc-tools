#!/usr/bin/env python3
"""Install a notarized distribution build, or explicitly authorized stable-signed local iteration.

    install.py                         build/DocKit.app
    install.py --app PATH/DocKit.app   a build elsewhere (package.py --out DIR)
    install.py --archive DocKit-v…zip  the released archive: the same package on another Mac
    install.py … --dest "/Applications/DocKit.app"
    install.py --local --app PATH    local iteration only; Developer ID, same team and requirement, no notarization

The default distribution path requires a package any Mac can run: Developer ID Application signature with the hardened runtime,
notarized by Apple with the ticket stapled, Gatekeeper reading "Notarized Developer ID", and no
provisioning profile that lists devices. The explicit local path retains the stable Developer ID signature,
team and designated requirement without invoking notarization; ad-hoc and Apple Development stay in build/.

Destination: the installed app that already has this bundle identifier; otherwise /Applications/DocKit.app,
or /Applications/DocKit Public.app when that name belongs to another app. The replaced copy moves to the
Trash (DOCKIT_RETIRE_DIR names the folder). A running copy is not replaced: quit it first.
After the move the installed app is checked again and asked for `status`.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import notarize  # noqa: E402  (the distribution check lives next to the step that earns it)

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "io.github.zengtianli.DocTools"


def bundle_id(app: Path) -> str | None:
    try: return plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    except (OSError, ValueError): return None


def destination() -> Path:
    names = [Path("/Applications/DocKit.app"), Path("/Applications/DocKit Public.app")]
    for candidate in names:
        if bundle_id(candidate) == BUNDLE_ID: return candidate
    for candidate in names:
        if not candidate.exists(): return candidate
    sys.exit("install: both DocKit.app and DocKit Public.app belong to other apps; pass --dest.")


def signing_identity(app: Path) -> tuple[str, str]:
    detail = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, check=True).stderr
    required = subprocess.run(["codesign", "-d", "-r-", str(app)], capture_output=True, text=True, check=True).stderr
    team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", detail, re.M)
    requirement = re.search(r"^designated => (.+)$", required, re.M)
    if not team or not requirement: raise ValueError("Signature has no stable team/designated requirement")
    return team.group(1), requirement.group(1)


def signed_facts(app: Path) -> dict:
    # Reuse the headquarters' signed-stage gate, including every nested Mach-O; no exception registration.
    shared = Path.home() / "Dev/tools/dev/lib/tools/macapp"
    sys.path.insert(0, str(shared))
    import distribution_grade
    return distribution_grade.inspect(app, stage="signed")


def policy_problems(app: Path, dest: Path | None, *, local: bool) -> list[str]:
    if not local: return notarize.notarized(app)
    facts = signed_facts(app)
    problems = list(facts["problems"])
    if problems: return problems
    team, requirement = signing_identity(app)
    if any(item["team"] != team for item in facts["nested"]):
        problems.append("Nested code does not preserve the app's developer team")
    if dest is not None and dest.exists() and signing_identity(dest) != (team, requirement):
        problems.append("Local iteration must preserve the installed developer team and designated requirement")
    return problems


def install(app: Path, dest: Path, *, local: bool = False) -> dict:
    if bundle_id(app) != BUNDLE_ID: sys.exit(f"install: {app} is not {BUNDLE_ID}.")
    if (problems := policy_problems(app, dest, local=local)):
        sys.exit("install: refused by " + ("local stable-signature" if local else "distribution") + " policy:\n  " + "\n  ".join(problems))
    if dest.exists() and bundle_id(dest) != BUNDLE_ID: sys.exit(f"install: {dest} is another app; nothing replaced.")
    if subprocess.run(["pgrep", "-f", f"{dest}/Contents/MacOS/"], capture_output=True).returncode == 0:
        sys.exit(f"install: {dest.name} is running; quit it and run this again. Nothing replaced.")
    staged = dest.with_name(f".{dest.name}.installing-{os.getpid()}")
    if staged.exists(): sys.exit(f"install: staging path already exists: {staged}; nothing replaced.")
    subprocess.run(["ditto", str(app), str(staged)], check=True)
    if (problems := policy_problems(staged, dest, local=local)):
        shutil.rmtree(staged)
        sys.exit("install: staged copy failed policy; old app unchanged:\n  " + "\n  ".join(problems))
    retired = None
    if dest.exists():
        folder = Path(os.environ.get("DOCKIT_RETIRE_DIR") or Path.home() / ".Trash" / "dockit-replaced")
        folder.mkdir(parents=True, exist_ok=True)
        retired = folder / f"{dest.stem} {time.strftime('%Y%m%d-%H%M%S')}.app"
        dest.rename(retired)
    try:
        staged.rename(dest)
        if (problems := policy_problems(dest, None, local=local)): raise RuntimeError("installed copy failed policy: " + "; ".join(problems))
        info = plistlib.loads((dest / "Contents/Info.plist").read_bytes())
        executable = "Contents/MacOS/" + info["CFBundleExecutable"]
        if hashlib.sha256((app / executable).read_bytes()).digest() != hashlib.sha256((dest / executable).read_bytes()).digest():
            raise RuntimeError("installed executable differs from the signed source")
        status = subprocess.run([str(dest / executable), "status", "--json"], capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, timeout=120)
        if status.returncode: raise RuntimeError(f"installed status exited {status.returncode}: {status.stderr.strip()}")
        readback = json.loads(status.stdout)
        if not readback["engine"]["ready"]: raise RuntimeError("installed document engine is not ready")
    except Exception:
        # Only the copy from this transaction is removed; the retired original is restored.
        if dest.exists(): shutil.rmtree(dest)
        if retired is not None: retired.rename(dest)
        if staged.exists(): shutil.rmtree(staged)
        raise
    return {"installed": str(dest), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "mode": "local-signed" if local else "distribution", "notarization": "not performed" if local else "verified",
            "gatekeeper": "not assessed for local iteration" if local else notarize.GRADE.split("=", 1)[1],
            "replaced": str(retired) if retired else None, "status_line": readback["engine"]["status_line"]}


def main() -> None:
    ap = argparse.ArgumentParser()
    source = ap.add_mutually_exclusive_group()
    source.add_argument("--app", type=Path, default=ROOT / "build/DocKit.app")
    source.add_argument("--archive", type=Path, help="install from a released archive instead of a build directory")
    ap.add_argument("--dest", type=Path)
    ap.add_argument("--local", action="store_true", help="explicit owner-authorized local iteration; stable Developer ID, same installed team/requirement, no notarization")
    cli = ap.parse_args()
    dest = cli.dest or destination()
    if cli.archive:
        with tempfile.TemporaryDirectory(prefix="dockit-install-") as temporary:
            subprocess.run(["ditto", "-x", "-k", str(cli.archive), temporary], check=True)
            result = install(Path(temporary) / "DocKit.app", dest, local=cli.local)
    else:
        result = install(cli.app.resolve(), dest, local=cli.local)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
