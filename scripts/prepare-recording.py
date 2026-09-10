#!/usr/bin/env python3
"""Prepare isolated, nonactivating recording copies; never launch or install them."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[1]
PRESETS = {
    "quotes": ("quotes", ["活动说明.docx"]),
    "convert": ("convert", ["活动说明.docx"]),
    "results": ("quotes", ["活动说明.docx", "不支持的图片.jpg"]),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source: Path, preset: str, batch: Path) -> dict:
    run = batch / preset
    run.mkdir(mode=0o700)
    for name in ("inputs", "outputs", "state", "state/python-home", "state/python-home/Downloads"):
        (run / name).mkdir(mode=0o700)
    source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    app = run / "DocKit.app"
    subprocess.run(["ditto", str(source), str(app)], check=True)
    identifier = f"io.github.zengtianli.DocTools.Recording.{uuid.uuid4().hex}.{preset}"
    operation, filenames = PRESETS[preset]
    env = {
        "DOCKIT_BACKGROUND": "1",
        "DOCKIT_RECORDING_ROOT": str(run),
        "DOCKIT_INPUT_DIR": str(run / "inputs"),
        "DOCKIT_OUTPUT_DIR": str(run / "outputs"),
        "DOCKIT_STATE_DIR": str(run / "state"),
        "DOCKIT_BACKEND_HOME": str(run / "state/python-home"),
        "DOCKIT_DEMO_OP": operation,
        "DOCKIT_DEMO_FILES": "\n".join(str(run / "inputs" / name) for name in filenames),
        "DOCKIT_NO_OPEN": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    generation_env = {key: value for key, value in os.environ.items()
                      if key not in {"PYTHONHOME", "PYTHONPATH"}}
    generation_env.update(env)
    generation_env["HOME"] = env["DOCKIT_BACKEND_HOME"]
    generation_env.pop("CFFIXED_USER_HOME", None)
    subprocess.run([str(app / "Contents/Resources/python/bin/python3.12"), "-s", "-B",
                    str(ROOT / "scripts/make-demo.py"), str(run / "inputs")],
                   env=generation_env, check=True, stdout=subprocess.DEVNULL)
    marker = {"kind": "dockit-recording-v1", "bundle_id": identifier}
    (run / ".dockit-recording.json").write_text(json.dumps(marker) + "\n")
    info = dict(source_info)
    info.update(CFBundleIdentifier=identifier, LSEnvironment=env, LSUIElement=True,
                NSSupportsAutomaticTermination=False, NSSupportsSuddenTermination=False)
    # Recording copies must not register as document handlers or URL schemes.
    for key in ("CFBundleDocumentTypes", "UTImportedTypeDeclarations", "UTExportedTypeDeclarations", "CFBundleURLTypes"):
        info.pop(key, None)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    executable = source_info["CFBundleExecutable"]
    source_hash = sha256(source / "Contents/MacOS" / executable)
    if sha256(app / "Contents/MacOS" / executable) != source_hash:
        raise RuntimeError("Recording copy unexpectedly changed the executable before signing")
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    manifest = {
        "kind": "dockit-recording-v1", "preset": preset, "app": str(app),
        "bundle_id": identifier, "version": source_info["CFBundleShortVersionString"],
        "build": source_info["CFBundleVersion"], "source_bundle_id": source_info["CFBundleIdentifier"],
        "source_executable_sha256": source_hash,
        "recording_executable_sha256": sha256(app / "Contents/MacOS" / executable),
        "environment": env,
        "preferences": "The unique recording bundle ID uses a separate preference domain; GUI HOME is not overridden.",
        "diagnostics": str(run / "state/launch-diagnostics.jsonl"),
        "inputs": [{"file": path.name, "sha256": sha256(path)} for path in sorted((run / "inputs").iterdir())],
        "launch": "Launch this copied app with activate:false; do not open the production bundle.",
        "shots": {
            "quotes": "Quotes selected; inspect options, then AX-click 执行.",
            "convert": "Convert selected; choose Markdown (.md) in the real format menu, then AX-click 执行.",
            "results": "Quotes selected with one DOCX and one unsupported JPG; AX-click 执行 to show partial success.",
        }[preset],
    }
    (run / "recording-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return {key: manifest[key] for key in ("preset", "app", "bundle_id", "version", "build", "shots", "diagnostics")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/DocKit.app")
    parser.add_argument("--preset", choices=PRESETS, default="quotes")
    parser.add_argument("--all", action="store_true", help="Prepare one separate copy per storyboard shot")
    args = parser.parse_args()
    source = args.app.resolve(strict=True)
    source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if source_info.get("CFBundleIdentifier") != "io.github.zengtianli.DocTools":
        parser.error("Use the public production DocKit build as the source, not another recording or installed private copy.")
    if not (source / "Contents/Resources/python/bin/python3.12").is_file():
        parser.error("The source app must contain the bundled Python runtime; run bash build.sh first.")
    batch = ROOT / "build/recording" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    batch.mkdir(mode=0o700, parents=True)
    batch = batch.resolve()
    copies = [prepare(source, preset, batch) for preset in (PRESETS if args.all else [args.preset])]
    print(json.dumps({"root": str(batch), "copies": copies, "launched": False}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
