#!/usr/bin/env python3
"""Install a notarized DocKit build into /Applications. Anything less than distribution grade is refused.

    install.py                         build/DocKit.app
    install.py --app PATH/DocKit.app   a build elsewhere (package.py --out DIR)
    install.py --archive DocKit-v…zip  the released archive: the same package on another Mac
    install.py … --dest "/Applications/DocKit.app"

The package must be one any Mac can run: Developer ID Application signature with the hardened runtime,
notarized by Apple with the ticket stapled, Gatekeeper reading "Notarized Developer ID", and no
provisioning profile that lists devices. Ad-hoc and Apple Development builds stay in build/.

Destination: the installed app that already has this bundle identifier; otherwise /Applications/DocKit.app,
or /Applications/DocKit Public.app when that name belongs to another app. The replaced copy moves to the
Trash (DOCKIT_RETIRE_DIR names the folder). A running copy is not replaced: quit it first.
After the move the installed app is checked again and asked for `status`.
"""
from pathlib import Path
import argparse
import json
import os
import plistlib
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


def install(app: Path, dest: Path) -> dict:
    if bundle_id(app) != BUNDLE_ID: sys.exit(f"install: {app} is not {BUNDLE_ID}.")
    if (problems := notarize.notarized(app)):
        sys.exit("install: refused, this is not a distribution package (run scripts/notarize.py on a Developer ID build):\n  " + "\n  ".join(problems))
    if dest.exists() and bundle_id(dest) != BUNDLE_ID: sys.exit(f"install: {dest} is another app; nothing replaced.")
    if subprocess.run(["pgrep", "-f", f"{dest}/Contents/MacOS/"], capture_output=True).returncode == 0:
        sys.exit(f"install: {dest.name} is running; quit it and run this again. Nothing replaced.")
    staged = dest.with_name(f".{dest.name}.installing-{os.getpid()}")
    subprocess.run(["ditto", str(app), str(staged)], check=True)
    retired = None
    if dest.exists():
        folder = Path(os.environ.get("DOCKIT_RETIRE_DIR") or Path.home() / ".Trash" / "dockit-replaced")
        folder.mkdir(parents=True, exist_ok=True)
        retired = folder / f"{dest.stem} {time.strftime('%Y%m%d-%H%M%S')}.app"
        dest.rename(retired)
    staged.rename(dest)
    if (problems := notarize.notarized(dest)): sys.exit(f"install: {dest} fails the distribution check after the move:\n  " + "\n  ".join(problems))
    info = plistlib.loads((dest / "Contents/Info.plist").read_bytes())
    status = subprocess.run([str(dest / "Contents/MacOS" / info["CFBundleExecutable"]), "status", "--json"],
                            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
    if status.returncode: sys.exit(f"install: the installed app's `status` exited {status.returncode}:\n{status.stderr.strip()}")
    return {"installed": str(dest), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "gatekeeper": notarize.GRADE.split("=", 1)[1], "replaced": str(retired) if retired else None,
            "status_line": json.loads(status.stdout)["engine"]["status_line"]}


def main() -> None:
    ap = argparse.ArgumentParser()
    source = ap.add_mutually_exclusive_group()
    source.add_argument("--app", type=Path, default=ROOT / "build/DocKit.app")
    source.add_argument("--archive", type=Path, help="install from a released archive instead of a build directory")
    ap.add_argument("--dest", type=Path)
    cli = ap.parse_args()
    dest = cli.dest or destination()
    if cli.archive:
        with tempfile.TemporaryDirectory(prefix="dockit-install-") as temporary:
            subprocess.run(["ditto", "-x", "-k", str(cli.archive), temporary], check=True)
            result = install(Path(temporary) / "DocKit.app", dest)
    else:
        result = install(cli.app.resolve(), dest)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
