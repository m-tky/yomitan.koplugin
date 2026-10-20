# Storefront / App Store compatibility

## Repository and release contract

- Repository: https://github.com/m-tky/yomitan.koplugin
- Plugin folder/ID: `yomitan.koplugin` / `yomitan`.
- `_meta.lua` provides a literal stable semantic `version`, `author`, GitHub `url`,
  GPL licence and a description stating the custom host-hook requirement.
- Plugin tags: `v<version>` matching `_meta.lua`.
- Plugin asset: `yomitan.koplugin.zip`, containing exactly one plugin folder.
- The ZIP includes all runtime modules, transform data, README and GPL licence,
  plus `plugin.json` with the version, required provider API and per-file hashes.
- A SHA-256 sidecar and GitHub asset digest support integrity checks.
- `jmdict-latest` is a **data-only** release, never the latest plugin release.
  Do not select its SQLite ZIP as a plugin archive.
- The repository uses the `koreader-plugin` topic for discovery. A topic is not a
  guarantee of inclusion in a curated catalog.

## Compatibility boundary

**Experimental and not compatible with stock KOReader.** The provider, candidate
and selection hooks are required in the host before lookup assistance can work.
These integration hooks are not yet available in a supported public KOReader
build. The updater and Storefront package never install or patch core hooks.
A safe refusal to enable on an incompatible host is not proof of compatibility.

This initial release is for integration testing. Do not promote it as a generally
usable stock-KOReader plugin until the required host integration is published.
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
