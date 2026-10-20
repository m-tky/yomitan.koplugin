"""Build a preconverted installer fixture with original synthetic entries, no network."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import zipfile

SPEC = importlib.util.spec_from_file_location("index_builder", Path(__file__).parents[1] / "build-jmdict-index.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def build(source, output):
    with tempfile.TemporaryDirectory() as temporary:
        fixture = Path(temporary) / "synthetic.zip"
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(fixture, "w") as archive:
            for name in original.namelist():
                data = original.read(name)
                if name == "index.json":
                    index = json.loads(data)
                    index["title"] = "JMdict [original synthetic installer fixture]"
                    index["attribution"] = "Original synthetic regression data, not JMdict content"
                    data = json.dumps(index, ensure_ascii=False, separators=(",", ":")).encode()
                archive.writestr(zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)), data)
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
        url = "https://github.com/yomidevs/jmdict-yomitan/releases/download/2026-01-01/JMdict_english.zip"
        metadata = {"tag_name": "2026-01-01", "assets": [{"name": BUILDER.ASSET,
            "browser_download_url": url, "digest": "sha256:" + digest, "size": fixture.stat().st_size}]}
        def download(address, destination, limit):
            body = fixture.read_bytes() if address == url else json.dumps(metadata).encode() if address.endswith("/latest") else b"Synthetic test document only, not a real dictionary licence."
            assert len(body) <= limit
            destination.write_bytes(body)
        return BUILDER.build(output, download=download)


if __name__ == "__main__":
    print(build(Path(sys.argv[1]), Path(sys.argv[2])))
