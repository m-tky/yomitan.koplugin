import hashlib
import importlib.util
import json
import re
import shutil
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_yomitan", ROOT / "tools/package-yomitan-plugin.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)
SOURCE = ROOT / "plugins/yomitan.koplugin"
if not SOURCE.exists():
    SOURCE = ROOT / "yomitan.koplugin"


class PackageTests(unittest.TestCase):
    def test_reproducible_archive_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / "a.zip", Path(directory) / "b.zip"
            self.assertRegex(PACKAGE.package(SOURCE, a), r"^\d+\.\d+\.\d+$")
            PACKAGE.package(SOURCE, b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            with zipfile.ZipFile(a) as archive:
                manifest = json.loads(archive.read("yomitan.koplugin/plugin.json"))
                self.assertEqual(manifest["provider_api"], 1)
                self.assertEqual(manifest["plugin_id"], "yomitan")
                self.assertEqual(len(archive.namelist()), len(manifest["files"]) + 1)
                for name, info in manifest["files"].items():
                    data = archive.read("yomitan.koplugin/" + name)
                    self.assertEqual(len(data), info["size"])
                    self.assertEqual(hashlib.sha256(data).hexdigest(), info["sha256"])
                self.assertIn("update-worker.lua", manifest["files"])
                self.assertIn("LICENSE", manifest["files"])
            self.assertTrue(a.with_suffix(".zip.sha256").exists())

    def test_rejects_incomplete_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                PACKAGE.package(Path(directory), Path(directory) / "out.zip")

    def test_excludes_user_data_and_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "yomitan.koplugin"
            shutil.copytree(SOURCE, source)
            (source / "settings.reader.lua").write_text("private settings")
            (source / ".verification-v1.json").write_text("private receipt")
            (source / "data").mkdir()
            (source / "data" / "dictionary.sqlite3").write_bytes(b"private dictionary")
            output = Path(directory) / "plugin.zip"
            PACKAGE.package(source, output)
            with zipfile.ZipFile(output) as archive:
                self.assertFalse(any("settings.reader" in name or "verification-v1" in name
                                     or "dictionary.sqlite3" in name for name in archive.namelist()))

    def test_licence_and_compatibility_warning_are_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "plugin.zip"
            PACKAGE.package(SOURCE, output)
            with zipfile.ZipFile(output) as archive:
                licence = archive.read("yomitan.koplugin/LICENSE").decode()
                self.assertIn("GNU GENERAL PUBLIC LICENSE", licence)
                self.assertNotIn("GNU AFFERO GENERAL", licence)
                self.assertIn("supported public KOReader build", archive.read("yomitan.koplugin/README.md").decode())

    def test_preconverted_installer_replaces_device_converter(self):
        importer = (SOURCE / "yomitan/importer.lua").read_text()
        self.assertNotIn("function Importer.prepare", importer)
        self.assertNotIn("CREATE TABLE", importer)
        self.assertIn("yomitan/bundle.lua", PACKAGE.REQUIRED)

    def test_source_has_storefront_metadata(self):
        meta = (SOURCE / "_meta.lua").read_text()
        self.assertIsNotNone(re.search(r'version\s*=\s*"\d+\.\d+\.\d+"', meta))
        self.assertIn('author = "m-tky"', meta)
        self.assertIn('url = "https://github.com/m-tky/yomitan.koplugin"', meta)


if __name__ == "__main__":
    unittest.main()
