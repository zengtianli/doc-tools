#!/usr/bin/env python3
"""Chapter acceptance of a real installed bundle, or an explicitly selected candidate and receipt.

Default: /Applications/DocKit Public.app + perf/build-receipt.json.
Candidate: --app PATH --receipt PATH, or DOCKIT_BASICS_APP / DOCKIT_BASICS_RECEIPT.
No compilation, product installation, release upload, real iCloud or desktop input occurs here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
PRODUCT = "io.github.zengtianli.DocTools"
FEATURES = ("settings", "shortcuts", "icloud", "updates")
SCENARIOS = {
    "settings.interaction": ["settings.ui_suite", "settings.actual_save_control", "settings.actual_close", "settings.never_visible_active_or_dock"],
    "settings.persisted_readback": ["settings.save_operation", "settings.fresh_readback", "settings.ui_saved_shortcut_readback"],
    "settings.error_preserves_data": ["settings.invalid_operation_refused", "settings.invalid_operation_preserves", "settings.invalid_import_refused", "settings.invalid_import_preserves"],
    "shortcuts.action_path": ["shortcuts.actual_menu_to_content_view_refresh", "shortcuts.fresh_readback"],
    "shortcuts.disable_restore": ["shortcuts.ui_disable_restore", "shortcuts.disable", "shortcuts.disabled_readback", "shortcuts.restore", "shortcuts.restored_readback"],
    "shortcuts.conflict_or_reserved_keys": ["shortcuts.ui_reserved_and_palette_conflicts", "shortcuts.reserved_key_refused", "shortcuts.palette_key_refused", "shortcuts.failed_binding_preserves"],
    "icloud.push_pull": ["icloud.actual_window_switch", "icloud.push", "icloud.cloud_contains_preferences", "icloud.receive", "icloud.remote_applied"],
    "icloud.unavailable_local_fallback": ["icloud.unavailable_error", "icloud.unavailable_preserves_local", "icloud.local_readback"],
    "icloud.conflict_or_corrupt_recovery": ["icloud.conflict_reconcile", "icloud.local_conflict_and_remote_independent_merge", "icloud.corrupt_error", "icloud.corrupt_preserves_local", "icloud.recovered"],
    "icloud.disable_preserves_data": ["icloud.disable", "icloud.disable_keeps_both_copies"],
    "updates.check_result": ["updates.fixture_result", "updates.actual_check_in_settings"],
    "updates.failure_recovery": ["updates.missing_feed_error", "updates.corrupt_feed_error", "updates.recovered"],
    "updates.options_or_store_entry": ["updates.actual_options_control", "updates.saved_options", "updates.fresh_options", "updates.invalid_options_refused", "updates.invalid_options_preserve"],
    "updates.data_preservation": ["updates.checks_and_preview_preserve_preferences", "updates.preview_only", "updates.owner_and_artifact_unchanged"],
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def owner_snapshot(app):
    prefs = subprocess.run(["/usr/bin/defaults", "export", PRODUCT, "-"], capture_output=True, timeout=10)
    canonical = plistlib.dumps(plistlib.loads(prefs.stdout), sort_keys=True) if prefs.returncode == 0 else b"missing"
    paths = [app / "Contents/MacOS/DocTools", app / "Contents/Info.plist", app / "Contents/Resources/AppIcon.icns",
             Path("/Applications/DocKit Public.app/Contents/MacOS/DocTools")]
    return {"production_preferences": hashlib.sha256(canonical).hexdigest(),
            "artifact_files": {str(p): sha(p) if p.is_file() else None for p in paths}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(os.environ.get("DOCKIT_BASICS_APP", "/Applications/DocKit Public.app")))
    parser.add_argument("--receipt", type=Path, default=Path(os.environ.get("DOCKIT_BASICS_RECEIPT", ROOT / "perf/build-receipt.json")))
    args = parser.parse_args()
    app, receipt_path = args.app.resolve(), args.receipt.resolve()
    spec = json.loads(os.environ["SOP_PRODUCT_BASICS_SPEC"])
    assert spec["app_id"] == os.environ["SOP_APP_ID"] == "doc-tools-oss"
    out = Path(os.environ["SOP_OUT_DIR"]).resolve()
    assert out.is_relative_to(ROOT / "perf/acceptance")
    run = out / ("product-basics-" + uuid.uuid4().hex)
    run.mkdir()
    checks, cases, binding = {}, [], {}
    error = None
    before = owner_snapshot(app)
    write(run / "owner-before.json", before)
    suite = PRODUCT + ".ProductBasics." + uuid.uuid4().hex

    def check(name, condition):
        checks[name] = bool(condition)

    try:
        assert app == Path("/Applications/DocKit Public.app") or app.is_relative_to(ROOT / "build"), "Choose the installed public bundle or this product's candidate"
        receipt = json.loads(receipt_path.read_text())
        artifact = receipt["artifact"]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        matched = (info["CFBundleIdentifier"] == artifact["bundle_id"] == PRODUCT
                   and str(info["CFBundleShortVersionString"]) == artifact["version"] == (ROOT / "VERSION").read_text().strip()
                   and str(info["CFBundleVersion"]) == artifact["build"]
                   and sha(app / artifact["executable"]) == artifact["sha256"]
                   and sha(app / artifact["icon"]["path"]) == artifact["icon"]["sha256"])
        # Reuse Chapter's exact snapshot contract, including additions/deletions; no second receipt engine.
        sys.path.insert(0, str(Path.home() / "Apps/chapter/engine"))
        import app_sop
        registration = app_sop.load_apps("doc-tools-oss")[0]
        source = app_sop.app_source_snapshot(registration, receipt["source"]["input_globs"], include_files=True)
        source_matches = source["sha256"] == receipt["source"]["sha256"] and source["files"] == receipt["source"]["files"]
        signed = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True, timeout=30)
        (run / "artifact-signature.log").write_text(signed.stdout + signed.stderr)
        for feature in FEATURES:
            check(feature + ".selected_artifact_matches_receipt", matched)
            check(feature + ".current_source_matches_receipt", source_matches)
            check(feature + ".artifact_signature_valid", signed.returncode == 0)
        assert matched and source_matches and signed.returncode == 0, "Artifact/source/receipt/signature mismatch; fixture not executed"
        binding = {"mode": "installed" if app.parent == Path("/Applications") else "candidate", "app": str(app),
                   "receipt": str(receipt_path.relative_to(ROOT)), "receipt_sha256": sha(receipt_path),
                   "source_sha256": source["sha256"], "executable_sha256": artifact["sha256"],
                   "bundle_id": PRODUCT, "version": artifact["version"], "build": artifact["build"],
                   "acceptor_sha256": sha(Path(__file__))}
        clone = run / "fixture/DocKit.app"
        shutil.copytree(app, clone, symlinks=True)
        check("settings.fixture_copied_original_executable", sha(clone / artifact["executable"]) == artifact["sha256"])
        info.update(CFBundleIdentifier=suite, LSUIElement=True)
        (clone / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(clone)], capture_output=True, check=True, timeout=60)
        binding["fixture_bundle_id"] = suite
        binding["fixture_resigned_executable_sha256"] = sha(clone / artifact["executable"])
        binary = clone / artifact["executable"]
        env = {k: v for k, v in os.environ.items() if not k.startswith(("APP_LIFECYCLE_", "DOCKIT_"))}
        env.update(APP_LIFECYCLE_SUPPORT_DIR=str(run / "support"), APP_LIFECYCLE_CLOUD_DIR=str(run / "cloud"),
                   DOCKIT_LIFECYCLE_SUITE=suite, DOCKIT_TEST_UPDATE_CHANNEL="isolated", PYTHONDONTWRITEBYTECODE="1")

        def call(name, words, predicate, code=0, override=None):
            completed = subprocess.run([str(binary), *words, "--json"], cwd=ROOT, env=override or env,
                                       capture_output=True, text=True, timeout=35)
            body = json.loads(completed.stdout)
            check(name, completed.returncode == code and predicate(body))
            cases.append({"check": name, "words": words, "exit": completed.returncode, "response": body,
                          "stderr": completed.stderr, "passed": checks[name]})
            return body

        def settings():
            result = subprocess.run([str(binary), "settings", "--json"], cwd=ROOT, env=env, capture_output=True, text=True, check=True, timeout=25)
            return json.loads(result.stdout)["settings"]

        call("settings.save_operation", ["settings", "set", "last_operation", "quotes"], lambda b: b["settings"]["last_operation"] == "quotes")
        call("settings.fresh_readback", ["settings"], lambda b: b["settings"]["last_operation"] == "quotes")
        baseline = settings()
        call("settings.invalid_operation_refused", ["settings", "set", "last_operation", "nonexistent-operation"], lambda b: b["error"]["code"] == "unknown_operation", 2)
        check("settings.invalid_operation_preserves", settings() == baseline)
        incoming = run / "invalid-import.json"
        write(incoming, {"version": 1, "product": "different-product", "values": {"dockit.lastOperation": "merge"}})
        call("settings.invalid_import_refused", ["config", "import", str(incoming), "--yes"], lambda b: b["error"]["code"] == "import_rejected", 1)
        check("settings.invalid_import_preserves", settings() == baseline)

        feed = run / "cloud/TianliApps/Updates" / suite / "isolated/release.json"
        feed.parent.mkdir(parents=True)
        # A real candidate archive supplies the digest/size; only the check record is a labelled private fixture.
        local_release = json.loads((app.parent / "release-manifest.json").read_text()) if app.parent != Path("/Applications") else json.loads((ROOT / "dist/release-manifest.json").read_text())
        archive = (app.parent if app.parent != Path("/Applications") else ROOT / "dist") / local_release["filename"]
        fixture_archive = feed.parent / archive.name
        shutil.copy2(archive, fixture_archive)
        fixture_release = {"version": artifact["version"], "build": str(int(artifact["build"]) + 1), "bundle_id": suite,
                           "channel": "isolated", "filename": archive.name, "sha256": sha(fixture_archive), "size_bytes": fixture_archive.stat().st_size,
                           "installation": "bundle"}
        write(feed, fixture_release)
        call("updates.fixture_result", ["update", "check"], lambda b: b["state"] == "update_available"
             and b["current"] == {"version": artifact["version"], "build": artifact["build"]}
             and b["latest"]["sha256"] == fixture_release["sha256"] and b["upgrade"]["button"])
        ui_env = dict(env, SOP_OUT_DIR=str(run / "ui"))
        (run / "ui").mkdir()
        completed = subprocess.run([str(binary), "--product-basics-self-test"], cwd=ROOT, env=ui_env,
                                   capture_output=True, text=True, timeout=105)
        (run / "ui.log").write_text(completed.stdout + completed.stderr)
        ui = json.loads(completed.stdout)
        write(run / "ui.json", ui)
        check("settings.ui_suite", completed.returncode == 0 and bool(ui["checks"]) and all(ui["checks"].values()))
        checks.update(ui["checks"])
        binding["ui"] = {"path": str((run / "ui.json").relative_to(ROOT)), "sha256": sha(run / "ui.json")}
        call("settings.ui_saved_shortcut_readback", ["shortcuts"], lambda b: b["binding"]["key"] == "t" and b["enabled"] is True)
        call("shortcuts.fresh_readback", ["shortcuts", "status"], lambda b: b["binding"]["key"] == "t" and b["scope"] == "application")
        call("shortcuts.disable", ["shortcuts", "off"], lambda b: b["enabled"] is False)
        call("shortcuts.disabled_readback", ["shortcuts"], lambda b: b["enabled"] is False and b["binding"]["key"] == "t")
        call("shortcuts.restore", ["shortcuts", "on"], lambda b: b["enabled"] is True)
        call("shortcuts.restored_readback", ["shortcuts"], lambda b: b["enabled"] is True and b["binding"]["key"] == "t")
        call("shortcuts.reserved_key_refused", ["shortcuts", "set", "q"], lambda b: "保留" in b["error"]["message"], 1)
        call("shortcuts.palette_key_refused", ["shortcuts", "set", "k"], lambda b: "搜索" in b["error"]["message"], 1)
        call("shortcuts.failed_binding_preserves", ["shortcuts"], lambda b: b["binding"]["key"] == "t")

        def reconcile(name, code=0, override=None):
            call(name + ".off", ["config", "sync", "off", "--yes"], lambda b: b["sync_enabled"] is False)
            return call(name, ["config", "sync", "on", "--yes"], lambda b: b.get("ok") is (code == 0), code, override)

        reconcile("icloud.push")
        cloud = run / "cloud" / (PRODUCT + ".json")
        remote = json.loads(cloud.read_text())
        check("icloud.cloud_contains_preferences", remote["values"]["defaults.dockit.lastOperation"] == "quotes"
              and remote["values"]["defaults.appShortcuts.refresh.binding"]["key"] == "t")
        remote["values"]["defaults.dockit.lastOperation"] = "merge"
        write(cloud, remote)
        reconcile("icloud.receive")
        check("icloud.remote_applied", settings()["last_operation"] == "merge")
        call("icloud.local_edit", ["settings", "set", "last_operation", "split"], lambda b: b["settings"]["last_operation"] == "split")
        remote["values"]["defaults.dockit.lastOperation"] = "quotes"
        remote["values"]["defaults.appShortcuts.refresh.enabled"] = False
        write(cloud, remote)
        reconcile("icloud.conflict_reconcile")
        check("icloud.local_conflict_and_remote_independent_merge", settings()["last_operation"] == "split")
        call("icloud.remote_independent_merge", ["shortcuts"], lambda b: b["enabled"] is False and b["binding"]["key"] == "t")
        checks["icloud.local_conflict_and_remote_independent_merge"] &= checks["icloud.remote_independent_merge"]
        local = settings()
        good_cloud = cloud.read_bytes()
        cloud.write_text("{broken")
        reconcile("icloud.corrupt_error", 1)
        check("icloud.corrupt_preserves_local", settings() == local)
        cloud.write_bytes(good_cloud)
        reconcile("icloud.recovered")
        unavailable = run / "unavailable-cloud"
        unavailable.write_text("not a directory")
        reconcile("icloud.unavailable_error", 1, dict(env, APP_LIFECYCLE_CLOUD_DIR=str(unavailable)))
        check("icloud.unavailable_preserves_local", settings() == local)
        call("icloud.local_readback", ["settings"], lambda b: b["settings"] == local)
        call("icloud.disable", ["config", "sync", "off", "--yes"], lambda b: b["sync_enabled"] is False)
        check("icloud.disable_keeps_both_copies", settings() == local and cloud.read_bytes() == good_cloud)

        call("updates.saved_options", ["update", "options", "--interval", "6", "--auto-download", "on", "--yes"], lambda b: b["options"]["intervalHours"] == 6)
        options = call("updates.fresh_options", ["update", "options"], lambda b: b["options"]["intervalHours"] == 6 and b["options"]["automaticDownload"] is True)["options"]
        call("updates.invalid_options_refused", ["update", "options", "--interval", "0", "--yes"], lambda b: b.get("ok") is False, 2)
        call("updates.invalid_options_preserve", ["update", "options"], lambda b: b["options"] == options)
        feed.unlink()
        call("updates.missing_feed_error", ["update", "check"], lambda b: b["error"]["code"] == "check_incomplete", 1)
        feed.write_text("{broken")
        call("updates.corrupt_feed_error", ["update", "check"], lambda b: b["error"]["code"] == "check_incomplete", 1)
        write(feed, fixture_release)
        call("updates.recovered", ["update", "check"], lambda b: b["state"] == "update_available")
        call("updates.preview_only", ["update", "install", "--dry-run"], lambda b: b.get("dry_run") is True and b.get("installed") is False)
        check("updates.checks_and_preview_preserve_preferences", settings() == local)
    except Exception as exc:
        error = str(exc)
        for feature in FEATURES:
            check(feature + ".execution_completed", False)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", suite], capture_output=True, timeout=15)
        after = owner_snapshot(app)
        write(run / "owner-after.json", after)
        for feature in FEATURES:
            check(feature + ".owner_and_artifact_unchanged", after == before)

    scope = "Real selected bundle and current-source receipt; private re-identified copy, original executable/backend, native settings/actions offscreen; local iCloud file chain, no Apple cross-device transfer; update fixture/check/dry-run only; no installation or publication."
    detail = {"schema_version": 1, "app_id": spec["app_id"], "spec_digest": spec["digest"], "features": {}, "scope": scope}
    for name, dependencies in SCENARIOS.items():
        check(name, all(checks.get(key) is True for key in dependencies))
    for feature in FEATURES:
        selected = {key: value for key, value in checks.items() if key.startswith(feature + ".")}
        raw = {"schema_version": 1, "app_id": spec["app_id"], "spec_digest": spec["digest"], "checks": selected,
               "binding": binding, "cases": [case for case in cases if case["check"].startswith(feature + ".")],
               "scenario_assertions": {key: dependencies for key, dependencies in SCENARIOS.items() if key.startswith(feature + ".")},
               "scope": scope, "error": error, "checked_at": time.time()}
        path = run / (feature + ".json")
        write(path, raw)
        detail["features"][feature] = {"result": "passed" if all(selected.values()) else "failed",
                                       "method": "ui_automation" if feature == "settings" else "real_product",
                                       "evidence": str(path.relative_to(ROOT)), "evidence_sha256": sha(path), "checks": list(selected)}
    passed = all(row["result"] == "passed" for row in detail["features"].values())
    detail["summary"] = f"DocKit {binding.get('mode', 'unbound')} 四项基本功能{'通过' if passed else '失败'}；14项必测汇总，iCloud为隔离文件链路，未验苹果跨设备传输"
    if error:
        detail["error"] = error
    write(out / "product_basics.detail.json", detail)
    print(detail["summary"])
    if not passed:
        print(json.dumps({"error": error, "failed_checks": [key for key, value in checks.items() if not value]}, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
