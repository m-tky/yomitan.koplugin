# Yomitan search assistance for KOReader

Japanese word selection and base-form/reading candidates using the pinned Yomitan
engine. **Only enabled StarDict dictionaries supply popup definitions.** This
plugin requires the dictionary-provider/candidate/selection hooks in
[m-tky/koreader-tategumi](https://github.com/m-tky/koreader-tategumi); it is not a
standalone solution for unmodified upstream KOReader. **Experimental: the required
host integration is not yet available in a supported public KOReader build.**
Storefront installation does not supply or patch those hooks. No MeCab is used.

## Setup and data updates

1. Install the plugin and restart KOReader. Keep your StarDict dictionaries
   installed and enabled in the normal dictionary settings.
2. In a book, first-time setup appears automatically. You can also long-press
   **Tools → More tools → Yomitan**, then choose **Add search index**.
3. Choose **Download/update JMdict**, review **Sources and licence**, then choose
   **Agree and download**. This explicitly contacts GitHub, downloads a
   **preconverted SQLite index ZIP**, verifies its published size/SHA-256, and
   extracts and checks it in a cancellable bundled LuaJIT worker.
4. After verification, confirm **Enable (keep long-press settings)** or
   **Enable + direct lookup**. The latter also enables direct dictionary opening
   after a word long-press. The dialog warns before globally disabling external
   dictionary lookup. **Keep installed without enabling** leaves lookup settings
   unchanged.

The device does **not** convert dictionaries. Original Yomitan v3 term ZIPs are no
longer accepted; the old on-device conversion pipeline has been removed. Python
conversion remains a CI/PC maintenance tool only. Internet and system curl are
needed for downloads, not for offline installation or lookup. No Node/Python is
required on the device. First verification can still take time on older Kindles;
this avoids slow dictionary conversion, not all integrity checks.

The fixed data endpoint is the `jmdict-latest` release in
`m-tky/yomitan.koplugin`, asset `JMdict-ja-terms.sqlite.zip`. **Until that data
release is published, automatic download reports that it is unavailable.** It
never falls back to a raw dictionary or an insecure download. Public publication
is a separate approval step. The data release is separate from semantic-version
plugin releases and must not be marked as the latest plugin release.

For offline testing, choose **Select preconverted index ZIP** and long-press a
ZIP produced by `tools/build-jmdict-index.py`. The downloaded ZIP from the earlier
local test is compatible. Do not unzip it yourself for this route. Alternatively,
previously copied complete content-ID directories can still use **Use installed
dictionaries**. Cancelling the chooser does not block reopening setup.

Use **Download/update JMdict** again to update dictionary data, with the same
consent and final activation confirmation. Downloads are never unattended. Code
updates do not update dictionary data. Immutable older generations are retained,
not overwritten. Automatic selection prefers the newest valid installed JMdict;
otherwise it preserves a real selection over a synthetic regression fixture.
There are no routine manual index-selection or verification settings.

## Installation safety

The worker preflights ZIP names, sizes and types; it never extracts archive paths
directly. The package must have exactly the declared database, manifest, source,
licence, documentation, original index and README payloads under `jmdict-index/`.
Only fixed, validated filenames are written into private same-filesystem staging.
Unknown files, missing notices, links, encrypted archives, path traversal,
duplicate/case-ambiguous names and invalid JSON are rejected.

Limits include a 128 MiB ZIP, a 512 MiB SQLite file, a 64 KiB package descriptor,
bounded documents, 5,000 ZIP entries and a 4 MiB central directory. The descriptor
must have the supported format/profile/converter version, content ID, source
provenance and per-file size/SHA-256. File hashes are checked while streaming;
the SQLite manifest must agree with the descriptor. Read-only SQLite schema,
metadata, quick-check and foreign keys are validated. Free space is checked
before extraction and repeatedly during writes, retaining a 24 MiB reserve.
No downloaded code is executed and no dictionary schema is migrated on-device.

Only the parent publishes the fully verified bundle by rename after worker exit.
Cancellation/reader close kills and reaps the worker before known staging cleanup;
startup recovery leaves live jobs and unknown files alone. Failed or cancelled
jobs retain existing indexes and lookup settings. Reinstalling an existing
content ID verifies it without overwriting it. The source ZIP is not deleted when
selected manually; a downloaded temporary ZIP is cleaned after the job.

Each installed content-ID directory retains `SOURCES.txt`, `JMdict-LICENSE.txt`,
`JMdict-documentation.html`, `JMdict-index.json`, `README.txt` and `package.json`
alongside the unchanged `manifest.json` and `dictionary.sqlite3`. **Sources and
licences** displays per-generation attribution and the local document location.
Legacy manually supplied notices remain visible too. Dictionary content and
receipts live outside the replaceable plugin directory.

Checksums provide integrity through trusted GitHub metadata, not independent
release signatures. Offline ZIP selection is an explicit trust decision; do not
install packages from untrusted sources. Do not mutate an installed bundle.

## Lookup behavior and caching

Press the **first character** of a Japanese word; selection is forward-only.
The original selected text is queried first in StarDict, followed by distinct
headwords/readings from the longest accepted Yomitan matches. The assistant never
uses glossary text for popup definitions. No-match preserves literal lookup, and
missing indexes do not silently add another Japanese deinflector. Disabling the
plugin restores the existing language-plugin route. Non-Japanese queries and
explicitly enabled external lookup retain their normal routing.

Existing StarDict enablement, per-book exclusions, HTML, links, resources,
history and cancellation remain on the normal dictionary path. No enabled
StarDict dictionary produces KOReader's normal no-dictionaries message.

Unchanged indexes reuse persisted verification receipts across restarts.
Receipts bind database hash/size/timestamps, the complete manifest hash and
verifier version, excluding unstable Kindle FSP/FUSE device/inode numbers.
Headers, schema and metadata still get lightweight checks. Missing, obsolete or
mismatched receipts cause full background verification; literal dictionary lookup
remains available. Reader close cancels pending work. This is a trusted local
cache, not protection against forged local metadata or a full bit-rot scan at
every startup. SQLite searches remain synchronous; StarDict batches candidates
through its normal sdcv path.

Search guards remain 20 source codepoints by default (maximum 32), 512 query
terms, 4,096 transformer states per input, 8,192 matched states and 4,096 exact
rows per stage. Candidate handoff is limited to 512 candidates/64 KiB and falls
back to the literal query rather than sending a partial candidate set.

## Plugin code updates

Opening **Tools → More tools → Yomitan** shows **Enabled** and **Check for
updates**. The latter checks semantic-version plugin releases, asks before staged
replacement, retains a backup and requires a normal KOReader restart. It never
patches core hooks or replaces settings/indexes. HTTPS requires curl and the
KOReader CA bundle, with no insecure TLS fallback. Power loss between backing up
and publishing plugin code may require manually restoring the retained backup.
Storefront/App Store publication and catalog listing remain separate steps.

## Acknowledgements and licence

Thank you to the [Yomitan](https://github.com/yomidevs/yomitan) and
[Yomichan](https://github.com/FooSoft/yomichan) authors and contributors for their
Japanese engine and linguistic work, and to the KOReader contributors for the
reader platform. This is an independent Lua adaptation, not an official Yomitan
project. Reference revision:
[`876253ca12e38aa6b0be3617e84827db5d9782b3`](https://github.com/yomidevs/yomitan/tree/876253ca12e38aa6b0be3617e84827db5d9782b3).
Upstream copyright notices and the 57-transform/928-rule descriptor are retained
in source and generated data.

The plugin is free software under GNU GPL version 3 or (at your option) any later
version (`GPL-3.0-or-later`); see [LICENSE](LICENSE). It is provided without
warranty. KOReader retains its own licence; this does not relicense the host.

JMdict data is separately licensed under CC BY-SA 4.0. Credit James William Breen
and the Electronic Dictionary Research and Development Group (EDRDG), and retain
the [EDRDG licence/documentation](https://www.edrdg.org/edrdg/licence.html).
Data is not included in the plugin ZIP. The regression fixture has only original
synthetic words and is not a general-purpose lexicon.

## Development

```sh
python3 -m unittest discover -s tools/tests -v
python3 tools/build-jmdict-index.py --release latest --output dist/JMdict-ja-terms.sqlite.zip
SDL_VIDEODRIVER=dummy nix develop --command ./kodev test front -f 'Yomitan'
```

CI/PC conversion accepts Japanese v3 term data, preserves original index and
term/glossary JSON in SQLite, and omits media. The schema/profile is unchanged,
so existing valid bundles remain usable. Do not commit personal dictionaries.
Native SQLite specs require isolated processes because their existing FFI binding
cannot be reliably reloaded across Busted file sandboxes.

Fork documentation records design, index packaging, release preparation and
Paperwhite 2 hardware tests. Earlier device conversion benchmarks are historical,
not the current installation pipeline. Automatic download of the new preconverted
format needs a published `jmdict-latest` data release for a public end-to-end test.
