# Yomitan for KOReader

Japanese word selection and base-form/reading candidates using the pinned Yomitan
engine. **Popup definitions come only from enabled StarDict dictionaries.**

> Uses KOReader's built-in language-support API; no custom host hooks or core
> patches are required. Experimental: device testing is still required.
> Disable the bundled **Japanese** plugin in Plugin Management and restart before
> enabling Yomitan: KOReader does not define priority between language plugins.
> Selection correction supports crengine documents (including EPUB), not PDF.

## Install

Download [`yomitan.koplugin.zip` from the latest plugin release](https://github.com/m-tky/yomitan.koplugin/releases/latest),
extract its single `yomitan.koplugin/` folder into KOReader's `plugins/` directory,
and restart KOReader. Do not install the `jmdict-latest` data release as a plugin.

The metadata and `.koplugin.zip` release layout support Storefront/App Store
installation and update matching. **Official catalog inclusion is separate and
has not been requested.** If the plugin is not in your store's catalog, install
the ZIP manually; do not assume adding a GitHub topic creates a listing.
See [Storefront compatibility](STOREFRONT.md).

LuaJIT, SQLite and libarchive are provided by KOReader. System curl and KOReader's
CA bundle are required for downloads and the built-in plugin updater.

## Setup and dictionary data

Open **Tools → More tools → Yomitan** for **Enabled** and **Check for updates**.
Long-press **Yomitan**, then choose **Add search index** to run setup.

Choose **Download/update JMdict**, review **Sources and licence**, and confirm
**Agree and download**. The plugin downloads `JMdict-ja-terms.sqlite.zip` from the
[separate `jmdict-latest` data release](https://github.com/m-tky/yomitan.koplugin/releases/tag/jmdict-latest),
checks the GitHub asset size/SHA-256, safely extracts the SQLite index, verifies
it and asks before enabling. **No dictionary conversion runs on the device.**
First extraction and verification can still take several minutes on older Kindles.
An unavailable data release is reported without falling back to a raw dictionary.

For offline installation use **Select preconverted index ZIP**. Original Yomitan
term ZIPs are not supported on-device. CI/PC conversion remains available for
maintainers. Existing immutable generations and settings survive failed/cancelled
jobs. Each installed generation retains its source/licence documents. Unchanged
indexes reuse persisted verification receipts across KOReader restarts.

Use **Download/update JMdict** again to update dictionary data. **Check for
updates updates plugin code only**, never dictionary data or KOReader core files.
Updates require explicit confirmation and a restart; a previous plugin backup is
retained. Sudden power loss during replacement may require restoring that backup.
Checksums rely on trusted GitHub metadata, not independent release signatures.

See [the runtime README](yomitan.koplugin/README.md) for safety limits, caching,
lookup behavior and installation details.

## Development and builds

Python 3.9+; portable tools use only the standard library:

```sh
python3 -m unittest discover -s tools/tests -v
python3 tools/package-yomitan-plugin.py --source yomitan.koplugin --output dist/yomitan.koplugin.zip
python3 tools/build-jmdict-index.py --release latest --output dist/JMdict-ja-terms.sqlite.zip
```

The plugin release workflow tests tooling and Lua syntax, checks that a pushed
`v<version>` tag matches `_meta.lua`, and publishes the plugin ZIP and checksum.

The manual **Build preconverted JMdict index** workflow accepts `latest` or a
`YYYY-MM-DD` upstream release. It builds and tests a separate data ZIP with source
provenance, per-file hashes, original index, CC BY-SA licence and EDRDG documents.
By default it saves a temporary Actions artifact. Explicit `publish=true` updates
`jmdict-latest` without marking it as the latest plugin release. Dictionary data
is never included in the plugin ZIP or committed to this repository.

Native reader/worker regression specs live in the integration fork's
`spec/unit/yomitan_*`. This repository is the standalone export; keep reviewed
runtime/tooling changes synchronized. See [release procedures](docs/RELEASING.md)
and [dictionary build/installer tests](docs/Yomitan_jmdict_index_build.md).

## Acknowledgements

Thank you to the [Yomitan](https://github.com/yomidevs/yomitan) and
[Yomichan](https://github.com/FooSoft/yomichan) authors and contributors for their
Japanese lookup engine, transforms and linguistic work, and to the KOReader
contributors for the reader platform. This is an independent Lua adaptation, not
an official Yomitan project or endorsement by its authors.

Reference revision:
[`876253ca12e38aa6b0be3617e84827db5d9782b3`](https://github.com/yomidevs/yomitan/tree/876253ca12e38aa6b0be3617e84827db5d9782b3).
Upstream notices and provenance remain in source and generated transform data.
`tools/generate-yomitan-japanese.mjs` regenerates the descriptor and native test
oracles from that clean, pinned upstream checkout. Node is required only for this
optional maintenance tool, never for plugin runtime or dictionary installation.

## Licence

Plugin: GNU General Public License version 3 or (at your option) any later version
(`GPL-3.0-or-later`); see [LICENSE](LICENSE). Provided without warranty. KOReader
retains its own licence; this does not relicense the host application.

JMdict data: separately licensed under CC BY-SA 4.0. Credit James William Breen
and the Electronic Dictionary Research and Development Group (EDRDG); retain the
[EDRDG licence/documentation](https://www.edrdg.org/edrdg/licence.html). Its source,
conversion notice and offline licence/documentation copies accompany the data ZIP
and each installed index generation. The plugin itself contains no dictionary data.
