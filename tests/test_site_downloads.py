"""Check the production site after scripts/build-site.py; no App rebuild or network."""
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "build/site"


class Links(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.anchors = []
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.anchors.append(dict(attrs))


class SiteDownloads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = json.loads((ROOT / "dist/release-manifest.json").read_text())
        cls.page = (SITE / "index.html").read_text()
        cls.links = Links(cls.page).anchors

    def test_download_buttons_and_checksum_use_github(self):
        base = self.release["download_url"].split("/releases/download/", 1)[0]
        expected = base + "/releases/tag/" + self.release["tag"]
        buttons = [link for link in self.links
                   if {"button", "nav-download"}.intersection(link.get("class", "").split())]
        self.assertEqual(len(buttons), 3)
        for link in buttons:
            self.assertEqual(link["href"], expected)
            self.assertNotIn("download", link)
        checksum = base + "/releases/download/" + self.release["tag"] + "/release-manifest.json"
        self.assertIn(checksum, [link.get("href") for link in self.links])
        self.assertNotIn("{{", self.page)

    def test_site_has_only_tutorial_downloads(self):
        local_links = {link.get("href") for link in self.links
                       if link.get("href", "").startswith("downloads/")}
        self.assertEqual(local_links, {"downloads/DocKit-demo-files.zip"})
        self.assertEqual({p.name for p in (SITE / "downloads").iterdir()}, {"DocKit-demo-files.zip"})
        for path in SITE.rglob("*"):
            self.assertNotIn(path.suffix.lower(), {".app", ".dmg", ".pkg", ".exe"})
            if path.is_file() and path.suffix.lower() == ".zip":
                self.assertEqual(path.relative_to(SITE).as_posix(), "downloads/DocKit-demo-files.zip")
                with zipfile.ZipFile(path) as samples:
                    self.assertEqual({Path(name).suffix for name in samples.namelist()},
                                     {".docx", ".md", ".csv", ".xlsx"})
        self.assertFalse((SITE / "downloads/release-manifest.json").exists())

    def test_site_manifest_and_source_release_remain_true(self):
        manifest = json.loads((SITE / "site-manifest.json").read_text())
        self.assertFalse(manifest["preview"])
        self.assertEqual(manifest["version"], self.release["version"])
        files = {item["path"]: item["sha256"] for item in manifest["files"]}
        actual = {p.relative_to(SITE).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in SITE.rglob("*") if p.is_file() and p.name != "site-manifest.json"}
        self.assertEqual(files, actual)
        archive = ROOT / "dist" / self.release["filename"]
        self.assertEqual(archive.stat().st_size, self.release["bytes"])
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), self.release["sha256"])
        facts = json.loads((SITE / "facts.json").read_text())
        self.assertEqual((facts["id"], facts["version"], str(facts["build"])),
                         ("doc-tools-oss", self.release["version"], str(self.release["build"])))

    def test_installation_and_measurement_scope_match_real_release(self):
        if "notarized by Apple; ticket stapled" in self.release.get("signing", ""):
            self.assertIn("已经 Apple 公证", self.page)
            self.assertNotIn("尚未经过 Apple 公证", self.page)
            self.assertNotIn("xattr -cr", self.page)
        measured = json.loads((ROOT / "perf/lightweight.json").read_text())["version"].split(" ")[0]
        if measured != self.release["version"]:
            self.assertIn("历史实测", self.page)
            self.assertIn(f"当前公开发行 {self.release['version']} ({self.release['build']})", self.page)
            self.assertIn("不代表当前发行包", self.page)
            facts = json.loads((SITE / "facts.json").read_text())
            self.assertEqual(facts["measurement_scope"], "historical measurement")


if __name__ == "__main__":
    unittest.main()
