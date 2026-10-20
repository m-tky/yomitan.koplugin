# Preconverted JMdict index build

## Scope

The standalone repository has a manually dispatched workflow at
`.github/workflows/jmdict-index.yml` named **Build preconverted JMdict index**.
It runs offline tooling tests, calls `tools/build-jmdict-index.py`, checks the
resulting ZIP and checksum, and uploads both as an Actions artifact for 30 days.
Build permissions are read-only. The optional boolean `publish` input (default
false) explicitly enables a separate `publish-index` job with contents-write
permission. It creates/updates the `jmdict-latest` data release and uploads the
ZIP/checksum with `--latest=false`, separate from semantic-version plugin releases.
There is no scheduled or unattended dictionary publication; publication requires
explicit approval and a manual workflow run with `publish=true`.

Input `release` accepts only `latest` or a `YYYY-MM-DD` upstream tag. It is passed
through an environment variable and quoted argument, not interpolated into shell
code. The workflow uses Python 3.12 and the standard library only. Its timeout is
30 minutes. Both the builder and tests also live under this fork's `tools/`.

```sh
python3 -m unittest discover -s tools/tests -v
python3 tools/build-jmdict-index.py --release latest --output dist/JMdict-ja-terms.sqlite.zip
```

## Source and packaging

The builder downloads release metadata from `yomidevs/jmdict-yomitan`, selects
exactly `JMdict_english.zip`, and requires the expected source URL, bounded size
and GitHub SHA-256 digest. Requested dated releases must match the API response.
Downloads use verified HTTPS, refuse HTTP downgrade redirects, bound transferred
bytes, and clean incomplete files. The build fails closed on missing licence or
documentation downloads. Checksums depend on trusted GitHub metadata and are not
independent release signatures.

The existing Python converter creates and validates the immutable SQLite bundle.
The dictionary ZIP has a single `jmdict-index/` root containing:

- `<content-id>/dictionary.sqlite3` and its existing compatible `manifest.json`;
- `SOURCES.txt`: EDRDG/Breen attribution, source release/URL/hash, converter
  version/profile, conversion changes and update instructions;
- `JMdict-LICENSE.txt`: downloaded CC BY-SA 4.0 legal text;
- `JMdict-documentation.html`: downloaded EDRDG licence/documentation statement;
- `JMdict-index.json`: original upstream dictionary metadata/attribution;
- `README.txt`: manual installation instructions and current limitations;
- `package.json`: format/kind, source identity, content ID, entry count, profile
  and every payload file's size/SHA-256 (excluding itself).

ZIP member metadata is fixed and the SQLite payload is streamed into the archive.
The build refuses an existing destination or checksum rather than silently
replacing a previous artifact. Repeated fixture builds are byte-identical in the
same environment; identical SQLite/zlib output across arbitrary toolchain versions
is not promised. The data package is separately licensed, not part of the GPL
plugin release archive. Converted data and downloaded dictionaries are not
committed to either repository.

## Installation limitations

The plugin now installs this format directly via **Select preconverted index
ZIP**. It also downloads the asset from the fixed
`m-tky/yomitan.koplugin/releases/tags/jmdict-latest` API endpoint after source/licence
consent. Publication is still a separately approved operation; until a data
release exists, the downloader reports that it is unpublished and offers local
ZIP selection. It never falls back to a raw term dictionary.

The old on-device Yomitan term-to-SQLite converter has been removed. `import.lua`
now downloads if requested, delegates extraction to `yomitan/bundle.lua`, verifies
existing selections, and returns proofs to the UI supervisor. Only the parent
publishes the immutable directory and asks before enabling. Each generation
retains its package metadata and all notices. Existing valid generations remain
compatible. The ZIP's original content ID and SQLite bytes are preserved.

Preflight requires the exact declared payload set, bounded file sizes, provenance,
profile/version and hash fields. Archive paths are never used as extraction
paths. Files are streamed to fixed private filenames while computing SHA-256;
manifest/descriptor metadata must agree before read-only SQLite schema, quick
check and foreign-key validation. Cancellation reaps the worker before bounded
cleanup. Original term ZIPs fail instead of invoking a converter. Tests cover
successful confirmation, offline and downloaded installation, idempotent installs,
source consent, cancellation/reader close, unsafe members, missing notices,
corrupt databases, forged hashes and space failures.

Manual PC extraction/copy of complete content-ID directories is still supported.
Never overwrite a live SQLite file. Actions artifacts expire and are not the
plugin's automatic source; the dedicated published data release is required.

## Verification (2026-10-20)

- All 23 portable tooling tests passed in the fork and standalone working copy,
  including nine builder tests covering fixture conversion, exact package file
  sets, per-file hashes, original attribution, offline licence copies, native
  SQLite integrity, reproducible fixture output, invalid metadata, wrong digests,
  pinned-release mismatch, HTTP downgrade rejection, byte limits, download
  failure cleanup and preservation of existing artifacts.
- `actionlint` 1.7.12 passed on the new workflow.
- The same CLI used by the workflow fetched and converted the real upstream
  `2026-10-19` release: 527,448 entries, ZIP size 48,614,623 bytes. All package
  hashes, the ZIP sidecar, exact payload set, SQLite integrity/foreign keys and
  entry count were checked after extraction.
- KOReader emulator LuaJIT opened the extracted real bundle through `Catalog.open`
  and passed search/source-length assertions for 独自, 読んでいる and 図書館.
- Local live-test artifacts are under `/tmp/jmdict-action-live/`.
- A fresh `--release latest` build selected the same upstream release and produced
  `/tmp/jmdict-kindle-download/JMdict-ja-terms.sqlite.zip`. Kindle curl downloaded
  all 48,614,623 bytes in 30.736 seconds from a temporary local HTTPS test server
  through an SSH reverse tunnel (direct LAN inbound access was unavailable).
  TLS used an explicitly trusted, temporary test certificate, never `--insecure`;
  this was not a download from a public GitHub release. The server, tunnel and
  temporary trust file were removed after testing.
- A separate Kindle test copy was downloaded with its `.sha256` sidecar.
  Device `sha256sum -c` passed. Its BusyBox unzip lacks `-t`,
  so the plugin's native libarchive-backed ZIP reader streamed all eight members
  and passed CRC validation (239,949,433 expanded bytes, 527,448 entries declared
  in the package metadata). No files were extracted, installed or reconverted,
  and no reader settings or existing index files were changed by this test.

## Preconverted installer verification

After replacing the on-device conversion path, all 52 focused native tests passed
across seven isolated suites (package installation, setup/activation, download,
FileManager, plugin updates, automatic selection and receipts). A subsequent run
of all ten isolated Yomitan suites passed **87 tests**, including search/provider
regressions and a real fresh-process download/install/activation test using an
offline transport fixture. All 23 portable Python tests and actionlint also passed. The public downloader is tested with a
fake release/download transport feeding a real synthetic package; no raw-term
fallback exists. Its 404 path explicitly reports unpublished data.

The real 527,448-entry ZIP was installed by the new fresh-process worker on both
the emulator and Paperwhite 2, using isolated staging rather than the user's live
index root. Kindle result was `prepared`, preserving content ID
`384c60a31de8bae5a26979853bba9137f0d4dce027ecb4551d3b3f925bf706ef` and database
SHA-256 `2af00dad5c9534c0e7e4840dda4b3e2709685efc9f6e613fbae579d07c535fc4`.
Device elapsed time was **3m 55.22s**, peak RSS **25,872 KiB**; extraction/checks
are not instantaneous, but no dictionary conversion occurred. Isolated device
results were recorded in isolated device QA storage. All device plugin files,
indexes, test downloads/documents, dedicated settings, QA history and backup copies
were subsequently deleted at the user's request; these results are historical,
not evidence of a current device installation.

## Initial public distribution verification

With explicit publication approval, the standalone repository and both releases
were published on 2026-10-20:

- Plugin: [v0.1.0](https://github.com/m-tky/yomitan.koplugin/releases/tag/v0.1.0),
  [successful release workflow](https://github.com/m-tky/yomitan.koplugin/actions/runs/39359196006).
- Data: [jmdict-latest](https://github.com/m-tky/yomitan.koplugin/releases/tag/jmdict-latest),
  [successful build/publish workflow](https://github.com/m-tky/yomitan.koplugin/actions/runs/39359198009).
- Both hosted builds passed all 26 current portable tests; plugin LuaJIT source
  compilation and data ZIP/sidecar checks also passed.
- GitHub `/releases/latest` still resolves to `v0.1.0`, not the data release.
- The actual plugin `Update.check`/`Update.prepare` and `Jmdict.download`/
  `Bundle.prepare` paths were exercised from the emulator using anonymous public
  HTTPS, not authenticated gh downloads. The plugin package validated, and the
  downloaded 527,448-entry data package extracted and passed SQLite checks.
- Released plugin ZIP SHA-256:
  `46367975b66b060f18f2ef26dcebbc85da75244ec7c7b68122924ff1f8678fa1`.
- Released data ZIP SHA-256:
  `721e7b3e4be831f30fe61f3862462681fa81bc6eef770a25fa503a8d2da10223`
  (48,614,725 bytes; its README reflects the current installer).

No device reinstallation was performed. Public distribution does not imply an
official Storefront catalog listing, which has not been requested, or stock-
KOReader compatibility. The required core integration remains unpublished.
