# Release procedures

## Compatibility and licensing

This is an experimental standalone plugin for custom KOReader provider/candidate/
selection hooks. Stock KOReader is not supported, and the required integration is
not yet available in a supported public build. Every release must keep this
warning prominent. A release ZIP never patches KOReader core files.

The plugin is GPL-3.0-or-later. Its generated transform data and ports retain
Yomitan/Yomichan notices and pinned provenance. JMdict data is CC BY-SA 4.0 and
belongs in a separate data ZIP with source, licence, documentation and conversion
notices, not in the plugin ZIP. Do not commit user dictionaries or settings.

## Plugin release

1. Synchronize reviewed changes with the integration fork and run its isolated
   native specs. Run `python3 -m unittest discover -s tools/tests -v` here.
2. Update the literal `_meta.lua` version and `docs/RELEASE_NOTES.md`.
3. Run actionlint and check that the package includes one `yomitan.koplugin/`
   folder, all required modules, README, GPL licence and `plugin.json` hashes:

   ```sh
   python3 tools/package-yomitan-plugin.py --source yomitan.koplugin --output dist/yomitan.koplugin.zip
   ```

4. Commit reviewed source and push it. After publication approval, push a matching
   `v<version>` tag. `release.yml` tests tooling, compiles Lua for syntax checks,
   rebuilds the ZIP and publishes it with the checksum and release notes. A manual
   dispatch builds/tests but does not publish without an explicitly pushed tag.
5. Confirm the Actions result, asset SHA-256, expected filenames and `/releases/latest`
   resolving to the semantic-version plugin release, not `jmdict-latest`.
6. Test the built-in updater against published metadata. Do not update a user's
   device without permission. Storefront catalog submission needs separate approval.

## Dictionary data release

Run **Build preconverted JMdict index** with `release=latest` (or a pinned upstream
`YYYY-MM-DD` tag). `publish=false` creates only an expiring build artifact. After
explicit approval, `publish=true` enables a separate contents-write job that
creates/updates `jmdict-latest` with `--latest=false` and uploads the data ZIP and
checksum. No schedule publishes dictionaries automatically.

The plugin uses that exact tag/asset API, validates GitHub's size/digest, then
installs the package in a cancellable worker. Original term-to-SQLite conversion
runs only on CI/PC. Existing generations are never overwritten; activation still
requires confirmation. See [index build and installer](Yomitan_jmdict_index_build.md).

After publishing, verify the release assets/digests, the archive's complete file
set and SQLite manifest, and that the plugin's stable release is still latest.
An authenticated API read is not proof that public unauthenticated downloads work;
check the public HTTPS route too. Never disable TLS validation for testing.

## Storefront contract and status

See [STOREFRONT.md](../STOREFRONT.md). Literal metadata, semantic tags and a
single-folder `.koplugin.zip` package support store installation/update matching;
curated catalog inclusion is not automatic and has not been requested.
