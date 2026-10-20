#!/usr/bin/env python3
"""Build a separate, attributed JMdict SQLite index ZIP (standard library only)."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import stat
import tempfile
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "yomidevs/jmdict-yomitan"
ASSET = "JMdict_english.zip"
LICENCE = "https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt"
DOCUMENTATION = "https://www.edrdg.org/edrdg/licence.html"
PREFIX = "jmdict-index/"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        if urllib.parse.urlsplit(url).scheme != "https":
            raise ValueError("Refusing a non-HTTPS redirect")
        return super().redirect_request(request, fp, code, message, headers, url)


def fetch(url, destination, limit):
    """Bounded authenticated HTTPS; never publish a partial download."""
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("HTTPS is required")
    request = urllib.request.Request(url, headers={"User-Agent": "koreader-jmdict-index-builder"})
    temporary = destination.with_suffix(destination.suffix + ".part")
    try:
        with urllib.request.build_opener(HTTPSRedirects()).open(request, timeout=120) as response, temporary.open("wb") as output:
            if response.status != 200:
                raise ValueError(f"Download failed: HTTP {response.status}")
            size = 0
            while chunk := response.read(65536):
                size += len(chunk)
                if size > limit:
                    raise ValueError("Download exceeds its size limit")
                output.write(chunk)
            if not size:
                raise ValueError("Empty download")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def release(data):
    if not isinstance(data, dict) or data.get("draft") or data.get("prerelease"):
        raise ValueError("A stable JMdict release is required")
    tag = data.get("tag_name")
    if not isinstance(tag, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", tag):
        raise ValueError("Unexpected JMdict release tag")
    assets = data.get("assets")
    if not isinstance(assets, list):
        raise ValueError("Missing JMdict assets")
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == ASSET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one JMdict English term ZIP")
    asset = matches[0]
    url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{ASSET}"
    digest, size = asset.get("digest"), asset.get("size")
    if (asset.get("browser_download_url") != url or not isinstance(digest, str)
            or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest)
            or type(size) is not int or not 0 < size <= 64 * 1024**2):
        raise ValueError("Invalid JMdict source URL, SHA-256 or size")
    return {"tag": tag, "url": url, "sha256": digest[7:], "size": size}


def load_converter():
    spec = importlib.util.spec_from_file_location("jmdict_sqlite_converter", Path(__file__).with_name("yomitan-to-sqlite.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package(directory, output):
    """Fixed ZIP metadata; stream the large SQLite file rather than buffering it."""
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in sorted(directory.rglob("*")):
                if path.is_symlink():
                    raise ValueError("Do not package symlinks")
                if not path.is_file():
                    continue
                info = zipfile.ZipInfo(PREFIX + path.relative_to(directory).as_posix(), (1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with path.open("rb") as source, archive.open(info, "w", force_zip64=True) as target:
                    shutil.copyfileobj(source, target, 1024 * 1024)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def build(output, tag="latest", download=fetch):
    output = Path(output)
    if tag != "latest" and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", tag):
        raise ValueError("Use latest or a YYYY-MM-DD upstream release tag")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Do not leave stale artifacts looking like a successful new build.
    if output.exists() or output.with_suffix(output.suffix + ".sha256").exists():
        raise ValueError("Output already exists; choose a fresh output path")
    with tempfile.TemporaryDirectory(prefix="jmdict-build-") as temporary:
        work = Path(temporary)
        metadata = work / "release.json"
        endpoint = "latest" if tag == "latest" else "tags/" + tag
        download(f"https://api.github.com/repos/{REPOSITORY}/releases/{endpoint}", metadata, 512 * 1024)
        if metadata.stat().st_size > 512 * 1024:
            raise ValueError("Oversized release metadata")
        selected = release(json.loads(metadata.read_text(encoding="utf-8")))
        if tag != "latest" and selected["tag"] != tag:
            raise ValueError("Requested release tag mismatch")
        source = work / ASSET
        download(selected["url"], source, selected["size"])
        if source.stat().st_size != selected["size"] or sha256(source) != selected["sha256"]:
            raise ValueError("JMdict ZIP checksum/size mismatch")
        payload = work / "payload"
        payload.mkdir()
        download(LICENCE, payload / "JMdict-LICENSE.txt", 256 * 1024)
        download(DOCUMENTATION, payload / "JMdict-documentation.html", 256 * 1024)
        converter = load_converter()
        bundle = converter.convert(source, payload)
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        if not manifest["title"].startswith("JMdict ["):
            raise ValueError("Unexpected dictionary title")
        with zipfile.ZipFile(source) as archive:
            (payload / "JMdict-index.json").write_bytes(archive.read("index.json"))
        (payload / "SOURCES.txt").write_text(
            "JMdict Japanese/English search index\n\n"
            "Copyright James William Breen and the Electronic Dictionary Research and Development Group (EDRDG).\n"
            "Dictionary data: CC BY-SA 4.0, separate from the plugin's GPL licence.\n"
            "https://creativecommons.org/licenses/by-sa/4.0/\n"
            f"Licence copy: JMdict-LICENSE.txt ({LICENCE})\n"
            f"Documentation copy: JMdict-documentation.html ({DOCUMENTATION})\n"
            "Project: https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project\n"
            f"Yomitan conversion: https://github.com/{REPOSITORY}\n"
            f"Upstream release: {selected['tag']}\nSource ZIP: {selected['url']}\n"
            f"Source SHA-256: {selected['sha256']}\n"
            f"Content ID: {bundle.name}\nConverter version: {converter.CONVERTER_VERSION}\n"
            f"Profile: {converter.PROFILE}\n"
            "Changes: converted Yomitan term data into SQLite; media omitted. Original index and glossary JSON retained.\n"
            "Used for word recognition and search candidates only; definitions come from enabled StarDict dictionaries.\n"
            "Not endorsed by EDRDG or Yomitan. No warranty.\n"
            "Updates: rebuild with the latest upstream release, install the new immutable generation, and retain its notices.\n",
            encoding="utf-8")
        (payload / "README.txt").write_text(
            "Preconverted JMdict search index for the KOReader Yomitan plugin\n\n"
            "In the current plugin, use Select preconverted index ZIP and long-press this ZIP.\n"
            "The worker extracts/verifies it and asks before enabling; no dictionary conversion runs on-device.\n"
            "Original Yomitan term ZIPs are not supported by the device installer.\n"
            "Alternatively extract on a PC and copy the CONTENTS of jmdict-index/ below koreader/data/yomitan/.\n"
            "Keep the complete content-ID directory, including manifest.json and dictionary.sqlite3,\n"
            "and retain SOURCES.txt and the licence/documentation files. Never overwrite an active\n"
            "database in place. Restart KOReader or enable Yomitan to verify/select the index.\n"
            "Existing generations may coexist. First device verification still takes time.\n"
            "This package does not enable Yomitan, change settings, or include StarDict definitions.\n"
            "Automatic acquisition uses the separately published jmdict-latest data release in m-tky/yomitan.koplugin.\n"
            "Verify the ZIP using its .sha256 sidecar. Checksums are not independent signatures.\n",
            encoding="utf-8")
        files = {path.relative_to(payload).as_posix(): {"size": path.stat().st_size, "sha256": sha256(path)}
                 for path in sorted(payload.rglob("*")) if path.is_file()}
        descriptor = {"format": 1, "kind": "jmdict-sqlite-index", "source": selected,
                      "content_id": bundle.name, "entry_count": manifest["entry_count"],
                      "profile": converter.PROFILE, "converter_version": converter.CONVERTER_VERSION, "files": files}
        (payload / "package.json").write_text(json.dumps(descriptor, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        package(payload, output)
    output.with_suffix(output.suffix + ".sha256").write_text(f"{sha256(output)}  {output.name}\n", encoding="ascii")
    return descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", default="latest", help="latest or YYYY-MM-DD upstream release tag")
    parser.add_argument("--output", type=Path, default=Path("dist/JMdict-ja-terms.sqlite.zip"))
    args = parser.parse_args()
    try:
        result = build(args.output, args.release)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"JMdict build failed: {error}\n")
    print(json.dumps({"output": str(args.output), "release": result["source"]["tag"],
                      "content_id": result["content_id"], "entry_count": result["entry_count"]}, sort_keys=True))


if __name__ == "__main__":
    main()
