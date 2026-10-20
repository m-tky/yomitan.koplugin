"""Generate original, deterministic native-test data using the real converter."""
import json
from pathlib import Path
import sys
import tempfile
import zipfile

from test_yomitan_to_sqlite import IMPORTER, term


def build(output, source_output=None):
    rows = [
        term("読む", "よむ", "v5"),
        term("読む", "よむ", "v1", ["Deliberately wrong POS for rejection tests"]),
        term("走る", "はしる", "v5"), term("食べる", "たべる", "v1"),
        term("美しい", "うつくしい", "adj-i"), term("図書館", "としょかん", ""),
        term("猫", "ねこ", ""), term("読了済", "どくりょうずみ", "", [["読む", ["fixture-form"]]]),
        term("空参照", "", "", [["存在しない", ["fixture-form"]]]),
        term("引用'語", "", "", ["A quote must be bound, not interpolated"]),
        term("構造", "こうぞう", "", [{"type": "structured-content", "content": {
            "tag": "div", "content": ["Safe <script>literal</script>", {"tag": "br"}, "second line"]}}]),
        term("先生", "せんせい", ""),
    ]
    files = {"index.json": {"title": "Original Yomitan regression fixture", "revision": "1", "format": 3,
                            "sourceLanguage": "ja", "attribution": "Original synthetic regression data"},
             "term_bank_1.json": rows}
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory) / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            for name, value in files.items():
                member = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                zipped.writestr(member, json.dumps(value, ensure_ascii=False, separators=(",", ":")))
        if source_output is not None:
            Path(source_output).write_bytes(archive.read_bytes())
        return IMPORTER.convert(archive, output)


if __name__ == "__main__":
    print(build(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) > 2 else None))
