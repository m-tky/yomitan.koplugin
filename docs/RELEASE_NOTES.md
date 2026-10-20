## v0.1.1

- Shorter setup, activation, progress and update messages; detailed information
  remains available under Sources and licences.
- One Enable action; existing long-press settings are no longer changed.
- Removed unused definition rendering, glossary retrieval and old term-streaming code.
- Hashing and plugin update checks no longer load SQLite through shared helpers;
  index verification loads it when needed.

Existing index files remain compatible. No dictionary rebuild or download is
required for this update. Runtime regression tests (89) and portable tooling tests
(26) passed before publication.

### Compatibility

**Experimental and not compatible with stock KOReader.** Requires custom
provider/candidate/selection hooks that are not yet available in a supported public
KOReader build. Storefront installation does not install or patch those hooks.
Official Storefront catalog inclusion has not been verified.

Install `yomitan.koplugin.zip` under KOReader's `plugins/` directory and restart.
`jmdict-latest` is a separate data-only release, not a plugin package. Plugin code
is GPL-3.0-or-later; JMdict data is CC BY-SA 4.0 with Breen/EDRDG attribution and
licence documents included in the data ZIP.
