## Experimental fork-only integration

**Not compatible with stock KOReader.** Requires custom dictionary-provider,
search-candidate and selection hooks from the KOReader-tategumi integration work.
These hooks are not yet available in a supported public KOReader build. Installing
this ZIP through Storefront does not install or patch them. This initial release
is for integration testing, not general stock-KOReader deployment.

- Japanese word selection and base-form/reading candidates using pinned Yomitan
  transforms; popup definitions remain exclusively in enabled StarDict dictionaries.
- Preconverted JMdict SQLite ZIP acquisition, bounded streaming extraction,
  integrity/schema checks, immutable publication and explicit activation confirmation.
- Persisted verification receipts; no on-device dictionary conversion.
- Storefront/App Store-compatible metadata and single-folder plugin ZIP.
- Confirmed plugin self-updates with backup; settings and indexes remain external.

Install `yomitan.koplugin.zip` below KOReader's `plugins/` directory and restart.
`jmdict-latest` is a separate CC BY-SA 4.0 data release, not a plugin release;
its ZIP includes Breen/EDRDG attribution, source provenance and licence documents.
The plugin code is GPL-3.0-or-later and retains Yomitan/Yomichan notices.

Portable tooling tests, isolated native regression suites and Paperwhite 2
isolated package extraction/verification have passed. Official Storefront catalog
submission and a Storefront-managed installation have not been performed.
