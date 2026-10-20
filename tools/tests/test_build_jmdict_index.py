import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("build_jmdict_index", Path(__file__).parents[1] / "build-jmdict-index.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class JmdictBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "fixture.zip"
        with zipfile.ZipFile(self.source, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("index.json", json.dumps({"format": 3, "title": "JMdict [original fixture]",
                "revision": "original-1", "sourceLanguage": "ja", "attribution": "Original test fixture only"}))
            archive.writestr("term_bank_1.json", json.dumps([
                ["読む", "よむ", None, "v5", 1, ["Original fixture"], 1, ""],
                ["図書館", "としょかん", None, "n", 1, ["Original fixture"], 2, ""]]))
        self.metadata = {"tag_name": "2026-01-01", "assets": [{"name": BUILDER.ASSET,
            "browser_download_url": "https://github.com/yomidevs/jmdict-yomitan/releases/download/2026-01-01/JMdict_english.zip",
            "size": self.source.stat().st_size, "digest": "sha256:" + BUILDER.sha256(self.source)}]}
        self.calls = []
        self.output = self.root / "dist" / "JMdict-ja-terms.sqlite.zip"

    def fetch(self, url, path, limit):
        self.calls.append(url)
        if "/releases/latest" in url or "/releases/tags/" in url:
            body = json.dumps(self.metadata).encode()
        elif url == BUILDER.LICENCE:
            body = b"Fixture licence text"
        elif url == BUILDER.DOCUMENTATION:
            body = b"Fixture documentation"
        elif url == self.metadata["assets"][0]["browser_download_url"]:
            body = self.source.read_bytes()
        else:
            self.fail("Unexpected download URL: " + url)
        self.assertLessEqual(len(body), limit)
        path.write_bytes(body)

    def build(self, **kwargs):
        return BUILDER.build(self.output, download=self.fetch, **kwargs)

    def test_roundtrip_package_hashes_licences_and_database(self):
        result = self.build()
        self.assertEqual(result["entry_count"], 2)
        self.assertEqual(result["source"]["tag"], "2026-01-01")
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(self.output.with_suffix(".zip.sha256").read_text(),
                         f"{BUILDER.sha256(self.output)}  {self.output.name}\n")
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertTrue(all(name.startswith("jmdict-index/") for name in archive.namelist()))
            descriptor = json.loads(archive.read("jmdict-index/package.json"))
            self.assertEqual(descriptor, result)
            self.assertEqual(set(archive.namelist()),
                             {BUILDER.PREFIX + name for name in result["files"]} | {BUILDER.PREFIX + "package.json"})
            for name, info in result["files"].items():
                body = archive.read(BUILDER.PREFIX + name)
                self.assertEqual(len(body), info["size"])
                self.assertEqual(hashlib.sha256(body).hexdigest(), info["sha256"])
            sources = archive.read("jmdict-index/SOURCES.txt").decode()
            for text in ("CC BY-SA 4.0", "Breen", "EDRDG", "2026-01-01", result["content_id"], "media omitted"):
                self.assertIn(text, sources)
            self.assertEqual(archive.read("jmdict-index/JMdict-LICENSE.txt"), b"Fixture licence text")
            self.assertEqual(archive.read("jmdict-index/JMdict-documentation.html"), b"Fixture documentation")
            self.assertIn("Original test fixture", archive.read("jmdict-index/JMdict-index.json").decode())
            database = self.root / "verify.sqlite3"
            database.write_bytes(archive.read(f"jmdict-index/{result['content_id']}/dictionary.sqlite3"))
            manifest = json.loads(archive.read(f"jmdict-index/{result['content_id']}/manifest.json"))
            self.assertEqual(manifest["content_id"], result["content_id"])
            self.assertEqual(manifest["files"]["dictionary.sqlite3"]["sha256"], BUILDER.sha256(database))
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            self.assertEqual(db.execute("SELECT term FROM entries ORDER BY id").fetchall(), [("読む",), ("図書館",)])
            self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_fixed_metadata_reproducible_archive(self):
        self.build()
        second = self.root / "second.zip"
        BUILDER.build(second, download=self.fetch)
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

    def test_rejects_unsafe_or_incomplete_release_metadata(self):
        mutations = [lambda d: d.update(draft=True), lambda d: d.update(prerelease=True),
            lambda d: d.update(tag_name="../bad"), lambda d: d.update(assets=[]),
            lambda d: d["assets"].append(d["assets"][0]),
            lambda d: d["assets"][0].update(browser_download_url="https://example.com/evil.zip"),
            lambda d: d["assets"][0].update(size=0), lambda d: d["assets"][0].update(size=True),
            lambda d: d["assets"][0].update(size=65 * 1024**2), lambda d: d["assets"][0].update(digest="bad")]
        for mutate in mutations:
            data = copy.deepcopy(self.metadata)
            mutate(data)
            with self.assertRaises(ValueError):
                BUILDER.release(data)

    def test_bad_checksum_fails_before_conversion_or_publication(self):
        self.metadata["assets"][0]["digest"] = "sha256:" + "0" * 64
        with patch.object(BUILDER, "load_converter") as converter:
            with self.assertRaisesRegex(ValueError, "checksum"):
                self.build()
            converter.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix(".zip.sha256").exists())

    def test_pinned_release_and_input_validation(self):
        self.build(tag="2026-01-01")
        self.assertTrue(self.calls[0].endswith("/releases/tags/2026-01-01"))
        for tag in ("../escape", "2026-01-01; echo injected", "--help"):
            with self.assertRaises(ValueError):
                BUILDER.build(self.root / "bad.zip", tag=tag, download=self.fetch)
        with self.assertRaisesRegex(ValueError, "tag mismatch"):
            BUILDER.build(self.root / "mismatch.zip", tag="2026-01-02", download=self.fetch)

    def test_failure_preserves_existing_output(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"previous package")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.build()
        self.assertEqual(self.output.read_bytes(), b"previous package")
        self.assertEqual(self.calls, [])

    def test_document_download_failure_publishes_nothing(self):
        def fail(url, path, limit):
            if url == BUILDER.LICENCE:
                raise OSError("Offline")
            self.fetch(url, path, limit)
        with self.assertRaises(OSError):
            BUILDER.build(self.output, download=fail)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix(".zip.sha256").exists())

    def test_no_plain_http_or_downgrade_redirect(self):
        with self.assertRaises(ValueError):
            BUILDER.fetch("http://example.com/source", self.root / "download", 10)
        with self.assertRaises(ValueError):
            BUILDER.HTTPSRedirects().redirect_request(None, None, 302, "", {}, "http://example.com/source")

    def test_fetch_bounds_and_partial_cleanup(self):
        class Response:
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                return b"oversized response"
        class Opener:
            def open(self, *args, **kwargs):
                return Response()
        destination = self.root / "download"
        with patch.object(BUILDER.urllib.request, "build_opener", return_value=Opener()):
            with self.assertRaisesRegex(ValueError, "size limit"):
                BUILDER.fetch("https://example.com/source", destination, 5)
        self.assertFalse(destination.exists())
        self.assertFalse(destination.with_suffix(".part").exists())


if __name__ == "__main__":
    unittest.main()
