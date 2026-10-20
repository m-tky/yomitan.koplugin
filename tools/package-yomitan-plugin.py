#!/usr/bin/env python3
"""Build the standalone Storefront/self-update ZIP, never including user data."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import zipfile

ROOT_FILES = {"_meta.lua", "main.lua", "import.lua", "update-worker.lua", "README.md", "LICENSE"}
REQUIRED = ROOT_FILES | {"yomitan/update.lua", "yomitan/update_ui.lua", "yomitan/update_net.lua",
    "yomitan/search.lua", "yomitan/transformer.lua", "yomitan/yomitan-transforms.json", "yomitan/database.lua",
    "yomitan/catalog.lua", "yomitan/verificationcache.lua", "yomitan/automatic.lua", "yomitan/setup.lua",
    "yomitan/importjob.lua", "yomitan/importer.lua", "yomitan/jsonstream.lua", "yomitan/zipreader.lua", "yomitan/jmdict.lua", "yomitan/bundle.lua"}


def package(source: Path, output: Path) -> str:
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Source must be a regular plugin directory")
    payload = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError("Do not package symlinks")
        if not path.is_file():
            continue
        name = path.relative_to(source).as_posix()
        allowed = name in ROOT_FILES or re.fullmatch(r"yomitan/[A-Za-z0-9_-]+\.lua", name) or name == "yomitan/yomitan-transforms.json"
        if allowed:
            data = path.read_bytes()
            if len(data) > 2 * 1024**2:
                raise ValueError("Plugin file exceeds limit")
            payload[name] = data
    if not REQUIRED <= payload.keys():
        raise ValueError(f"Missing plugin files: {sorted(REQUIRED - payload.keys())}")
    match = re.search(rb'^\s*version\s*=\s*"(\d{1,6}\.\d{1,6}\.\d{1,6})"', payload["_meta.lua"], re.MULTILINE)
    if not match or any(len(p) > 1 and p.startswith(b"0") for p in match[1].split(b".")):
        raise ValueError("A literal stable semantic version is required in _meta.lua")
    version = match[1].decode("ascii")
    manifest = {"format": 1, "plugin_id": "yomitan", "provider_api": 1, "version": version,
                "files": {name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                          for name, data in payload.items()}}
    payload["plugin.json"] = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if len(payload) > 128 or sum(map(len, payload.values())) > 16 * 1024**2:
        raise ValueError("Plugin archive exceeds limits")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            entry = zipfile.ZipInfo("yomitan.koplugin/" + name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    if output.stat().st_size > 8 * 1024**2:
        output.unlink()
        raise ValueError("Compressed plugin ZIP exceeds limit")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="ascii")
    return version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/yomitan.koplugin.zip"))
    args = parser.parse_args()
    print(package(args.source, args.output))
