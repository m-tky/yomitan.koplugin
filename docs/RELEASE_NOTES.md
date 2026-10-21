## v0.1.2

- Replaced fork-only dictionary-provider hooks with KOReader's built-in
  language-support API. No KOReader core changes or monkey patches are needed.
- Migrated legacy Yomitan enablement to an independent `yomitan_enabled` setting.
- Kept StarDict definitions, setup, background verification and safe shutdown.
- Disable the bundled Japanese plugin and restart before enabling Yomitan;
  language-plugin priority is undefined. Selection correction is crengine-only.
- Language-support contract tests (including KOReader's actual dispatcher), all
  26 portable tooling tests, and LuaJIT source-syntax checks passed.
- Stock-device end-to-end validation is still pending.

Install `yomitan.koplugin.zip` under KOReader's `plugins/` directory and restart.
Keep StarDict dictionaries installed and enabled; Yomitan provides search
assistance, not popup definitions. No index rebuild or download is required.

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

### Historical compatibility (v0.1.1 only)

**Experimental and not compatible with stock KOReader.** Requires custom
provider/candidate/selection hooks that are not yet available in a supported public
KOReader build. Storefront installation does not install or patch those hooks.
Official Storefront catalog inclusion has not been verified.

Install `yomitan.koplugin.zip` under KOReader's `plugins/` directory and restart.
`jmdict-latest` is a separate data-only release, not a plugin package. Plugin code
is GPL-3.0-or-later; JMdict data is CC BY-SA 4.0 with Breen/EDRDG attribution and
licence documents included in the data ZIP.
