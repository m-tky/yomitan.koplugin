# Storefront / App Store compatibility

## Repository and release contract

- Repository: https://github.com/m-tky/yomitan.koplugin
- Plugin folder/ID: `yomitan.koplugin` / `yomitan`.
- `_meta.lua` provides a literal stable semantic `version`, `author`, GitHub `url`,
  GPL licence and a description stating the language-plugin compatibility boundary.
- Plugin tags: `v<version>` matching `_meta.lua`.
- Plugin asset: `yomitan.koplugin.zip`, containing exactly one plugin folder.
- The ZIP includes all runtime modules, transform data, README and GPL licence,
  plus `plugin.json` with the version and per-file hashes. The legacy
  `provider_api = 1` package-format marker is retained for updater compatibility;
  it no longer indicates a dependency on custom KOReader hooks.
- A SHA-256 sidecar and GitHub asset digest support integrity checks.
- `jmdict-latest` is a **data-only** release, never the latest plugin release.
  Do not select its SQLite ZIP as a plugin archive.
- The repository uses the `koreader-plugin` topic for discovery. A topic is not a
  guarantee of inclusion in a curated catalog.

## Compatibility boundary

Uses KOReader's built-in language-support API; no custom provider, candidate or
selection hooks are needed. The updater and Storefront package never patch core
files. Disable the bundled Japanese plugin and restart before enabling Yomitan;
language-plugin priority is undefined. Selection correction supports crengine
documents, not PDF. Stock-device end-to-end validation remains necessary.
Storefront itself is not bundled, installed or replaced by this project.

## Catalog status and manual installation

No official Storefront/App Store catalog submission has been made. Installation
from a release ZIP remains available even when a store has no matching entry.
Extract `yomitan.koplugin/` below KOReader's `plugins/` directory and restart.
An installed plugin's literal GitHub URL/version can support store update
matching where the store provides that feature. Maintainers must follow the
current catalog's discovery/submission process for an actual listing; there is
no fabricated catalog entry or repository ID in this repository.

Reference implementations:

- https://github.com/ultimatejimmy/storefront.koplugin
- https://github.com/omer-faruq/appstore.koplugin

## Validation

Portable tests check metadata, archive layout, deterministic file manifests and
exclusion of settings/dictionaries. The release workflow runs these tests and
LuaJIT source-syntax checks before publishing. Native host integration, worker,
installer, update and search regressions are maintained in the integration fork.
Official catalog discovery and a Storefront-managed installation are separate
checks, not implied by passing the package tests.
