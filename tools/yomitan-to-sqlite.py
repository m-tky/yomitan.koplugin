#!/usr/bin/env python3
"""Convert a Yomitan v3 Japanese term ZIP to an immutable KOReader SQLite bundle.

Python standard library only. Media are not extracted or rendered by this profile.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import tempfile
import zipfile

APPLICATION_ID = 0x594F4D49  # YOMI
SCHEMA_VERSION = 1
CONVERTER_VERSION = 1
PROFILE = "ja-terms-v3-text-v1"
MAX_JSON_DEPTH = 64
MAX_INTEGER = 2**53 - 1  # Exact in the reader's Lua number representation.
SCHEMA = """
CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE entries(
 id INTEGER PRIMARY KEY, source_bank INTEGER NOT NULL, source_row INTEGER NOT NULL,
 term TEXT NOT NULL, reading TEXT NOT NULL, definition_tags TEXT, rules TEXT NOT NULL,
 score REAL NOT NULL, glossary_json TEXT NOT NULL, sequence INTEGER NOT NULL,
 term_tags TEXT NOT NULL, definition_count INTEGER NOT NULL, form_count INTEGER NOT NULL,
 UNIQUE(source_bank, source_row));
CREATE TABLE lookup_keys(
 key TEXT COLLATE BINARY NOT NULL, entry_id INTEGER NOT NULL REFERENCES entries(id),
 PRIMARY KEY(key,entry_id));
CREATE TABLE tags(name TEXT PRIMARY KEY, raw_json TEXT NOT NULL);
CREATE TABLE form_links(
 entry_id INTEGER NOT NULL REFERENCES entries(id), glossary_position INTEGER NOT NULL,
 target_term TEXT NOT NULL, inflection_rules_json TEXT NOT NULL,
 PRIMARY KEY(entry_id,glossary_position));
CREATE TABLE assets(
 archive_path TEXT PRIMARY KEY, relative_path TEXT NOT NULL, media_type TEXT NOT NULL,
 byte_size INTEGER NOT NULL, sha256 TEXT NOT NULL);
"""


class ImportError(ValueError):
    """Invalid, unsupported, or unsafe dictionary input."""


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def digest_file(file):
    file.seek(0)
    digest = hashlib.sha256()
    for chunk in iter(lambda: file.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def string(value, name, nullable=False):
    if nullable and value is None:
        return value
    if not isinstance(value, str) or "\0" in value:
        raise ImportError(f"{name} must be a string without NULs")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ImportError(f"{name} contains invalid Unicode") from error
    return value


def number(value, name, integer=False):
    try:
        finite = type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise ImportError(f"{name} must be finite numeric data, not a boolean")
    if integer and (type(value) is not int or abs(value) > MAX_INTEGER):
        raise ImportError(f"{name} must be an exactly representable integer")
    return value


def validate_tree(value, depth=0):
    if depth > MAX_JSON_DEPTH:
        raise ImportError("JSON nesting exceeds the supported limit")
    if isinstance(value, str):
        string(value, "JSON string")
    elif isinstance(value, list):
        for child in value:
            validate_tree(child, depth + 1)
    elif isinstance(value, dict):
        for key, child in value.items():
            string(key, "JSON key")
            validate_tree(child, depth + 1)
    elif type(value) in (int, float):
        number(value, "JSON number")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ImportError(f"Duplicate JSON property: {key}")
        result[key] = value
    return result


def read_json(archive, member, max_bank_bytes):
    if member.file_size > max_bank_bytes:
        raise ImportError(f"JSON bank too large: {member.filename}")
    with archive.open(member) as stream:
        content = stream.read(max_bank_bytes + 1)
    if len(content) > max_bank_bytes:
        raise ImportError(f"JSON bank too large: {member.filename}")
    try:
        result = json.loads(content.decode("utf-8-sig"), object_pairs_hook=no_duplicates,
                            parse_constant=lambda value: (_ for _ in ()).throw(ImportError(f"Invalid number: {value}")))
        validate_tree(result)
        return result
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ImportError(f"Invalid JSON in {member.filename}: {error}") from error


def members_of(archive, max_total_bytes):
    members, aliases = {}, set()
    total = 0
    infos = archive.infolist()
    if len(infos) > 100000:
        raise ImportError("Too many ZIP members")
    for member in infos:
        name = member.filename
        path = PurePosixPath(name)
        # Deliberately conservative even for resources that this profile ignores.
        if (not name or member.orig_filename != name or "\\" in name or ":" in name
                or "\0" in name or path.is_absolute() or any(part in (".", "..", "") for part in name.rstrip("/").split("/"))
                or stat.S_ISLNK(member.external_attr >> 16) or member.flag_bits & 1):
            raise ImportError(f"Unsafe or encrypted ZIP member: {name!r}")
        alias = name.rstrip("/").casefold()
        if alias in aliases:
            raise ImportError(f"Duplicate/ambiguous ZIP member: {name}")
        aliases.add(alias)
        total += member.file_size
        if total > max_total_bytes or (member.file_size > 1024 * 1024 and member.file_size > max(member.compress_size, 1) * 2000):
            raise ImportError("ZIP expansion limit exceeded")
        if not member.is_dir():
            members[name] = member
    return members


def term_row(row):
    if not isinstance(row, list) or len(row) != 8:
        raise ImportError("A v3 term row must have exactly eight fields")
    term, reading, tags, rules, score, glossary, sequence, term_tags = row
    string(term, "term")
    string(reading, "reading")
    string(tags, "definition tags", nullable=True)
    string(rules, "deinflection rules")
    if any(len(value.encode("utf-8")) > 4096 for value in (term, reading, rules)):
        raise ImportError("Term, reading, or rule field exceeds the supported size")
    number(score, "score")
    number(sequence, "sequence", integer=True)
    string(term_tags, "term tags")
    if not isinstance(glossary, list):
        raise ImportError("Glossary must be an array")
    links, definition_count = [], 0
    for position, definition in enumerate(glossary):
        if isinstance(definition, list):
            if (len(definition) != 2 or not isinstance(definition[0], str)
                    or not isinstance(definition[1], list) or not all(isinstance(rule, str) for rule in definition[1])):
                raise ImportError("Invalid dictionary-provided form link")
            links.append((position, definition[0], encoded(definition[1])))
        elif isinstance(definition, str):
            definition_count += 1
        elif isinstance(definition, dict):
            kind = definition.get("type")
            if kind not in ("text", "structured-content", "image"):
                raise ImportError(f"Unsupported glossary object type: {kind!r}")
            if kind == "text" and not isinstance(definition.get("text"), str):
                raise ImportError("Text glossary object needs text")
            if kind == "structured-content" and "content" not in definition:
                raise ImportError("Structured glossary object needs content")
            if kind == "image" and not isinstance(definition.get("path"), str):
                raise ImportError("Image glossary object needs path")
            definition_count += 1
        else:
            raise ImportError("Unsupported glossary item")
    glossary_json = encoded(glossary)
    if len(glossary_json.encode("utf-8")) > 4 * 1024 * 1024:
        raise ImportError("Glossary entry exceeds the 4 MiB reader payload limit")
    return (term, reading, tags, rules, score, glossary_json, sequence, term_tags, definition_count, len(links)), links


def convert(source_path, output_root, *, max_bank_bytes=64 * 1024 * 1024,
            max_total_bytes=2 * 1024**3, max_entries=5000000):
    """Return a completed bundle path. Never modify an existing generation."""
    source_path, output_root = Path(source_path), Path(output_root)
    if min(max_bank_bytes, max_total_bytes, max_entries) <= 0:
        raise ImportError("Import limits must be positive")
    output_root.mkdir(parents=True, exist_ok=True)
    stage = None
    try:
        with source_path.open("rb") as source:
            if source.seek(0, os.SEEK_END) > max_total_bytes:
                raise ImportError("Source archive exceeds the size limit")
            source_hash = digest_file(source)
            with zipfile.ZipFile(source) as archive:
                members = members_of(archive, max_total_bytes)
                if "index.json" not in members:
                    raise ImportError("Missing root index.json")
                index = read_json(archive, members["index.json"], min(max_bank_bytes, 1024 * 1024))
                if not isinstance(index, dict):
                    raise ImportError("Index must be an object")
                version = index.get("format", index.get("version"))
                if type(version) is not int or version != 3 or any(
                        type(index[key]) is not int or index[key] != 3 for key in ("format", "version") if key in index):
                    raise ImportError("Only Yomitan format 3 is supported")
                string(index.get("title"), "dictionary title")
                string(index.get("revision"), "dictionary revision")
                if max(len(index[key].encode("utf-8")) for key in ("title", "revision")) > 4096:
                    raise ImportError("Title/revision exceeds the supported size")
                if not index["title"] or index.get("sourceLanguage", "ja") not in ("ja", "jpn"):
                    raise ImportError("A Japanese term dictionary is required")
                banks = []
                for name, member in members.items():
                    match = re.fullmatch(r"term_bank_([1-9][0-9]*)\.json", name)
                    if match:
                        if len(match[1]) > 16:
                            raise ImportError("Term bank number exceeds the supported range")
                        banks.append((int(match[1]), member))
                banks.sort()
                if not banks:
                    raise ImportError("No v3 term banks (frequency/pitch/kanji-only archives are unsupported)")
                identity = {"archive_sha256": source_hash, "schema_version": SCHEMA_VERSION,
                            "converter_version": CONVERTER_VERSION, "profile": PROFILE}
                content_id = hashlib.sha256(encoded(identity).encode()).hexdigest()
                destination = output_root / content_id
                if destination.exists():
                    raise ImportError(f"Bundle already exists; it was not modified: {destination}")
                stage = Path(tempfile.mkdtemp(prefix=".import-", dir=output_root))
                db_path = stage / "dictionary.sqlite3"
                connection = sqlite3.connect(db_path)
                count = 0
                try:
                    connection.executescript(f"PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON;\n{SCHEMA}")
                    connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
                    connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
                    connection.execute("BEGIN")
                    for bank_number, member in banks:
                        number(bank_number, "bank number", integer=True)
                        rows = read_json(archive, member, max_bank_bytes)
                        if not isinstance(rows, list):
                            raise ImportError("Term bank must be an array")
                        for row_number, row in enumerate(rows):
                            count += 1
                            if count > max_entries:
                                raise ImportError("Entry count limit exceeded")
                            fields, links = term_row(row)
                            cursor = connection.execute("INSERT INTO entries VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                                                        (count, bank_number, row_number, *fields))
                            entry_id = cursor.lastrowid
                            for key in dict.fromkeys((fields[0], fields[1])):
                                if key:
                                    connection.execute("INSERT INTO lookup_keys VALUES(?,?)", (key, entry_id))
                            connection.executemany("INSERT INTO form_links VALUES(?,?,?,?)",
                                                   ((entry_id, *link) for link in links))
                    if count == 0:
                        raise ImportError("Term banks contain no entries")
                    for name in sorted(members):
                        if not re.fullmatch(r"tag_bank_[1-9][0-9]*\.json", name):
                            continue
                        rows = read_json(archive, members[name], max_bank_bytes)
                        if not isinstance(rows, list):
                            raise ImportError("Tag bank must be an array")
                        for row in rows:
                            if not isinstance(row, list) or len(row) != 5:
                                raise ImportError("Tag row must have five fields")
                            string(row[0], "tag name")
                            string(row[1], "tag category")
                            number(row[2], "tag order")
                            string(row[3], "tag notes")
                            number(row[4], "tag score")
                            connection.execute("INSERT INTO tags VALUES(?,?)", (row[0], encoded(row)))
                    metadata = {"identity": identity, "content_id": content_id, "index": index,
                                "entry_count": count, "profile": PROFILE}
                    connection.executemany("INSERT INTO metadata VALUES(?,?)", ((key, encoded(value)) for key, value in metadata.items()))
                    connection.commit()
                    if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)] or connection.execute("PRAGMA foreign_key_check").fetchone():
                        raise ImportError("Generated database failed integrity checks")
                finally:
                    connection.close()
                warnings = []
                if "minimumYomitanVersion" in index:
                    warnings.append("minimumYomitanVersion is preserved but is not a compatibility guarantee for this plugin")
                if any(not re.fullmatch(r"(?:index|term_bank_[0-9]+|tag_bank_[0-9]+)\.json", name) for name in members):
                    warnings.append("Additional metadata/media files were not imported by the term/text profile")
                manifest = {**identity, "content_id": content_id, "title": index["title"], "revision": index["revision"],
                            "entry_count": count, "warnings": warnings, "media": "not-copied", "files": {}}
                with db_path.open("rb") as db_file:
                    manifest["files"]["dictionary.sqlite3"] = {"size": db_path.stat().st_size, "sha256": digest_file(db_file)}
                manifest_path = stage / "manifest.json"
                with manifest_path.open("w", encoding="utf-8") as output:
                    output.write(encoded(manifest) + "\n")
                    output.flush()
                    os.fsync(output.fileno())
                # Detect a source changed during conversion before publishing.
                if digest_file(source) != source_hash:
                    raise ImportError("Source ZIP changed during import")
                os.rename(stage, destination)
                stage = None
                return destination
    except (sqlite3.Error, zipfile.BadZipFile, RuntimeError, UnicodeError) as error:
        raise ImportError(str(error)) from error
    finally:
        if stage is not None:
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--max-bank-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--max-total-bytes", type=int, default=2 * 1024**3)
    parser.add_argument("--max-entries", type=int, default=5000000)
    arguments = parser.parse_args()
    try:
        destination = convert(arguments.archive, arguments.output_directory, max_bank_bytes=arguments.max_bank_bytes,
                              max_total_bytes=arguments.max_total_bytes, max_entries=arguments.max_entries)
    except (ImportError, OSError) as error:
        parser.exit(1, f"Import failed: {error}\n")
    print(destination)


if __name__ == "__main__":
    main()
