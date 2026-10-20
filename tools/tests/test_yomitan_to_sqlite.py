import importlib.util
import json
from pathlib import Path
import sqlite3
import stat
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location("yomitan_to_sqlite", Path(__file__).parents[1] / "yomitan-to-sqlite.py")
IMPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORTER)


def term(word="読む", reading="よむ", rules="v5", glossary=None):
    return [word, reading, None, rules, 1.5, ["Original definition"] if glossary is None else glossary, -1, "common"]


def archive(path, rows=None, extra=None, index=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as output:
        output.writestr("index.json", json.dumps(index or {"title": "Original test dictionary", "revision": "1", "format": 3,
                                                         "sourceLanguage": "ja", "attribution": "Original test data"}))
        if rows is not False:
            output.writestr("term_bank_1.json", json.dumps(rows if rows is not None else [term()], ensure_ascii=False))
        for name, value in (extra or {}).items():
            output.writestr(name, value)


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "dictionary.zip"
        self.output = self.root / "bundles"

    def convert(self, **kwargs):
        return IMPORTER.convert(self.source, self.output, **kwargs)

    def assert_rejected(self, **kwargs):
        with self.assertRaises((IMPORTER.ImportError, sqlite3.Error)):
            self.convert(**kwargs)
        self.assertEqual(list(self.output.glob(".import-*")), [])

    def test_roundtrip_fields_readings_homographs_and_forms(self):
        glossary = [{"type": "structured-content", "content": {"tag": "div", "content": "説明"}}, ["読む", ["-た"]]]
        rows = [term(), term(glossary=glossary), term("読んだ", "よんだ", "", [["読む", ["-た"]]])]
        archive(self.source, rows, {"tag_bank_1.json": json.dumps([["common", "frequency", 0.5, "common word", -0.5]])})
        bundle = self.convert()
        with sqlite3.connect(bundle / "dictionary.sqlite3") as db:
            self.assertEqual(db.execute("PRAGMA application_id").fetchone()[0], IMPORTER.APPLICATION_ID)
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)
            row = db.execute("SELECT term,reading,definition_tags,rules,score,glossary_json,sequence,term_tags,definition_count,form_count FROM entries WHERE id=2").fetchone()
            self.assertEqual(row[:5], ("読む", "よむ", None, "v5", 1.5))
            self.assertEqual(json.loads(row[5]), glossary)
            self.assertEqual(row[6:], (-1, "common", 1, 1))
            self.assertEqual(db.execute("SELECT definition_count,form_count FROM entries WHERE id=3").fetchone(), (0, 1))
            self.assertEqual(db.execute("SELECT count(*) FROM lookup_keys WHERE key='よむ'").fetchone()[0], 2)
            self.assertEqual(db.execute("SELECT count(*) FROM form_links").fetchone()[0], 2)
            self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
        manifest = json.loads((bundle / "manifest.json").read_text())
        self.assertEqual(manifest["entry_count"], 3)
        self.assertEqual(manifest["content_id"], bundle.name)
        self.assertEqual(manifest["profile"], IMPORTER.PROFILE)
        self.assertTrue(manifest["files"]["dictionary.sqlite3"]["sha256"])
        self.assertFalse((bundle / "dictionary.sqlite3-wal").exists())

    def test_same_term_and_reading_have_one_key(self):
        archive(self.source, [term("猫", "猫", "")])
        with sqlite3.connect(self.convert() / "dictionary.sqlite3") as db:
            self.assertEqual(db.execute("SELECT count(*) FROM lookup_keys").fetchone(), (1,))

    def test_published_bundle_is_never_overwritten(self):
        archive(self.source)
        bundle = self.convert()
        before = (bundle / "dictionary.sqlite3").read_bytes()
        self.assert_rejected()
        self.assertEqual(before, (bundle / "dictionary.sqlite3").read_bytes())

    def test_identity_includes_conversion_profile(self):
        archive(self.source)
        first = self.convert()
        profile = IMPORTER.PROFILE
        try:
            IMPORTER.PROFILE = "another-profile"
            self.assertNotEqual(first, self.convert())
        finally:
            IMPORTER.PROFILE = profile

    def test_unsupported_or_metadata_only_archives(self):
        for index in ({"format": 2, "title": "Old", "revision": "1"},
                      {"format": 3, "version": 2, "title": "Conflict", "revision": "1"},
                      {"format": 3, "title": "English", "revision": "1", "sourceLanguage": "en"}):
            archive(self.source, index=index)
            self.assert_rejected()
        archive(self.source, False, {"term_meta_bank_1.json": "[]"})
        self.assert_rejected()
        archive(self.source, [])
        self.assert_rejected()

    def test_invalid_rows_and_nonfinite_numbers(self):
        invalid = [term()[:-1], term(glossary=[False]), term(glossary=[["読む", "bad chain"]]),
                   term(glossary=[{"type": "script", "content": "bad"}])]
        for field, value in ((4, True), (4, float("nan")), (4, float("inf")), (6, 2**60), (0, "bad\0term")):
            row = term()
            row[field] = value
            invalid.append(row)
        for row in invalid:
            archive(self.source, [row])
            self.assert_rejected()

    def test_limits_rollback_and_leave_existing_revision(self):
        archive(self.source)
        previous = self.convert()
        archive(self.source, [term(), term("食べる")])
        for limits in ({"max_entries": 1}, {"max_bank_bytes": 8}, {"max_total_bytes": 8}):
            self.assert_rejected(**limits)
        self.assertTrue((previous / "dictionary.sqlite3").exists())
        self.assertEqual(len(list(self.output.iterdir())), 1)

    def test_cancellation_removes_staging_and_preserves_previous_generation(self):
        archive(self.source)
        previous = self.convert()
        archive(self.source, [term(), term("食べる")])
        original = IMPORTER.term_row
        calls = 0

        def interrupted(row):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt()
            return original(row)

        try:
            IMPORTER.term_row = interrupted
            with self.assertRaises(KeyboardInterrupt):
                self.convert()
        finally:
            IMPORTER.term_row = original
        self.assertEqual(list(self.output.glob(".import-*")), [])
        self.assertEqual(list(self.output.iterdir()), [previous])
        self.assertTrue((previous / "dictionary.sqlite3").exists())

    def test_unsafe_members_rejected_even_when_not_extracted(self):
        for name in ("../escape", "/absolute", "a/../escape", "a\\escape", "C:escape", "./alias"):
            archive(self.source, extra={name: "bad"})
            self.assert_rejected()
        archive(self.source)
        with zipfile.ZipFile(self.source, "a") as output:
            member = zipfile.ZipInfo("symlink")
            member.create_system = 3
            member.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(member, "outside")
        self.assert_rejected()

    def test_duplicate_members_or_json_keys_rejected(self):
        archive(self.source, extra={"INDEX.JSON": "{}"})
        self.assert_rejected()
        archive(self.source)
        with zipfile.ZipFile(self.source, "w") as output:
            output.writestr("index.json", '{"format":3,"format":3,"title":"bad","revision":"1"}')
        self.assert_rejected()

    def test_resources_not_extracted_and_original_json_preserved(self):
        image = {"type": "image", "path": "images/test.png"}
        archive(self.source, [term(glossary=[image])], {"images/test.png": "not decoded", "term_meta_bank_1.json": "[]"})
        bundle = self.convert()
        self.assertFalse((bundle / "images").exists())
        self.assertTrue(json.loads((bundle / "manifest.json").read_text())["warnings"])
        with sqlite3.connect(bundle / "dictionary.sqlite3") as db:
            self.assertEqual(json.loads(db.execute("SELECT glossary_json FROM entries").fetchone()[0]), [image])


if __name__ == "__main__":
    unittest.main()
