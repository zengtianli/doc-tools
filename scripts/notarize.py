#!/usr/bin/env python3
"""Notarize the Developer ID build made by package.py, staple the ticket, and refresh archive + manifest.

    notarize.py                release layout: build/DocKit.app + dist/ archive and manifest
    notarize.py --dir DIR      a build made with `package.py --out DIR` (DOCKIT_OUT)

Order: check the signature (Developer ID, hardened runtime, no ad-hoc file, no provisioning profile that
lists devices) → submit the archive to Apple's notary service and wait → staple → `stapler validate` and
Gatekeeper (`spctl`, must read "Notarized Developer ID") → re-create the archive from the stapled app and
write its size, hash and signing line into the manifest. Notarization submits the package to Apple; it
publishes nothing. A failed submission keeps Apple's log next to the archive (notary-log.json).

Credentials, first match: DOCKIT_NOTARY_PROFILE (a `notarytool store-credentials` keychain profile);
NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (App Store Connect API key file, id, issuer); the maintainer's
shared loader (~/Dev/tools/dev/lib/tools/macapp/ios/asc.py). Nothing secret is stored or printed here.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
GRADE = "source=Notarized Developer ID"


def out(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def device_profiles(app: Path) -> list[str]:
    """Embedded provisioning profiles that list devices: such a package only runs on those Macs."""
    listed = []
    for profile in app.rglob("embedded.provisionprofile"):
        decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True)
        if decoded.returncode or b"ProvisionedDevices" in decoded.stdout: listed.append(str(profile.relative_to(app)))
    return listed


def grade(app: Path) -> list[str]:
    """What keeps this app from being a package any Mac can run; empty when it is distribution grade."""
    problems = []
    if out(["codesign", "--verify", "--deep", "--strict", str(app)]).returncode: problems.append("signature does not verify")
    detail = out(["codesign", "-dvv", str(app)]).stderr
    if "Authority=Developer ID Application" not in detail: problems.append("not signed with a Developer ID Application certificate")
    if not re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", detail): problems.append("no hardened runtime")
    if "Timestamp=" not in detail: problems.append("no secure timestamp")
    problems += [f"provisioning profile lists devices: {p}" for p in device_profiles(app)]
    return problems


def notarized(app: Path) -> list[str]:
    problems = grade(app)
    if out(["xcrun", "stapler", "validate", str(app)]).returncode: problems.append("no stapled notarization ticket")
    assessment = out(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])
    if GRADE not in assessment.stdout + assessment.stderr: problems.append("Gatekeeper does not read Notarized Developer ID")
    return problems


def credentials() -> list[str]:
    profile = os.environ.get("DOCKIT_NOTARY_PROFILE")
    if profile: return ["--keychain-profile", profile]
    key, kid, issuer = (os.environ.get(n) for n in ("NOTARY_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER"))
    if not (key and kid and issuer):
        helper = Path.home() / "Dev/tools/dev/lib/tools/macapp/ios"
        if not (helper / "asc.py").is_file():
            sys.exit("notarize: no credentials. Set DOCKIT_NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER.")
        sys.path.insert(0, str(helper))
        import asc
        kid, issuer = asc._personal_env("ASC_KEY_ID"), asc._personal_env("ASC_ISSUER_ID")
        key = str(Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{kid}.p8")
    return ["--key", key, "--key-id", kid, "--issuer", issuer]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, help="directory of a `package.py --out DIR` build (default: build/ + dist/)")
    ap.add_argument("--timeout", default="30m", help="how long to wait for Apple's verdict (default 30m)")
    cli = ap.parse_args()
    base = (ROOT / cli.dir).resolve() if cli.dir and not cli.dir.is_absolute() else cli.dir
    app = (base or ROOT / "build") / "DocKit.app"
    dist = base or ROOT / "dist"
    manifest_path = dist / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    archive = dist / manifest["filename"]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (manifest["version"], manifest["build"]):
        sys.exit("notarize: the app and the manifest are different builds; run package.py again.")
    if (problems := grade(app)): sys.exit("notarize: not a distribution build (fail-closed):\n  " + "\n  ".join(problems))
    if not notarized(app):
        print("Already notarized and stapled; nothing submitted.")
    else:
        if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest["sha256"]:
            sys.exit("notarize: the archive is not the one its manifest describes; run package.py again.")
        done = out(["xcrun", "notarytool", "submit", str(archive), *credentials(), "--wait", "--timeout", cli.timeout, "--output-format", "json"])
        try: verdict = json.loads(done.stdout)
        except ValueError: sys.exit(f"notarize: notarytool gave no verdict (exit {done.returncode}).")
        print(json.dumps({k: verdict.get(k) for k in ("id", "status", "message")}))
        if verdict.get("status") != "Accepted":
            if verdict.get("id"):
                log = out(["xcrun", "notarytool", "log", verdict["id"], *credentials(), str(dist / "notary-log.json")])
                print(f"Apple's log: {dist / 'notary-log.json'}" if not log.returncode else "Apple's log could not be fetched.")
            sys.exit("notarize: Apple did not accept the package.")
        manifest["notary_submission"] = verdict["id"]
        subprocess.run(["xcrun", "stapler", "staple", str(app)], check=True)
    if (problems := notarized(app)): sys.exit("notarize: stapled app fails the distribution check:\n  " + "\n  ".join(problems))
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if hashlib.sha256(executable.read_bytes()).hexdigest() != manifest["source_executable_sha256"]:
        sys.exit("notarize: the executable changed since package.py recorded it.")
    # The archive people download carries the ticket, so the first launch needs no network.
    archive.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    authority = re.search(r"Authority=(Developer ID Application:[^\n]+)", out(["codesign", "-dvv", str(app)]).stderr).group(1)
    manifest.update(bytes=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                    signing=f"{authority}; hardened runtime; notarized by Apple; ticket stapled")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
