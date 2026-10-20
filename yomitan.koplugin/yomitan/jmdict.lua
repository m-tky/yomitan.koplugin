-- Opt-in acquisition of CI-built SQLite indexes, never raw term dictionaries.
local JSON = require("rapidjson")
local Jmdict = {
    repository = "m-tky/yomitan.koplugin",
    tag = "jmdict-latest",
    asset = "JMdict-ja-terms.sqlite.zip",
}
Jmdict.notice = [[JMdict preconverted search index

Copyright James William Breen and the Electronic Dictionary Research and Development Group (EDRDG).
Data licence: CC BY-SA 4.0, separate from the plugin's GPL licence.
https://creativecommons.org/licenses/by-sa/4.0/
https://www.edrdg.org/edrdg/licence.html
https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project

Original Yomitan-format data: https://github.com/yomidevs/jmdict-yomitan
SQLite conversion and distribution: https://github.com/m-tky/yomitan.koplugin

CI converts the Japanese/English term data to SQLite. The device only downloads, extracts and verifies it; there is no on-device dictionary conversion. Glossary data is retained but definitions are displayed only from enabled StarDict dictionaries. This is not an endorsement by EDRDG or Yomitan.

Download requires internet and curl. GitHub receives the request. The ZIP is checked against GitHub's published SHA-256 digest, not an independent signature. Verification can take time and can be cancelled. Source, licence and documentation copies are retained with each installed index. Existing indexes are not overwritten. Lookup settings change only after final confirmation.

Use Download/update JMdict again to obtain updated data. Plugin code updates do not update dictionaries. Until a data release is published, use Select preconverted index ZIP with a locally built package.
]]

function Jmdict.release(data)
    assert(type(data) == "table" and not data.draft and not data.prerelease and data.tag_name == Jmdict.tag,
        "Unexpected preconverted JMdict release")
    local found
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == Jmdict.asset then
            assert(not found, "Duplicate JMdict asset")
            local url = "https://github.com/" .. Jmdict.repository .. "/releases/download/" .. Jmdict.tag .. "/" .. Jmdict.asset
            local hash = type(asset.digest) == "string" and asset.digest:match("^sha256:([a-f0-9]+)$")
            assert(asset.browser_download_url == url, "Unexpected JMdict download URL")
            assert(hash and #hash == 64, "Missing JMdict SHA-256 digest")
            assert(type(asset.size) == "number" and asset.size > 0 and asset.size <= 128 * 1024^2 and asset.size % 1 == 0,
                "Unsupported JMdict package size")
            found = {url = url, sha256 = hash, size = asset.size}
        end
    end
    return assert(found, "No compatible preconverted JMdict ZIP in this release")
end

function Jmdict.download(stage, progress, fetch)
    local Importer = require("yomitan/importer")
    local lfs = require("libs/libkoreader-lfs")
    fetch = fetch or require("yomitan/update_net").fetch
    local function get(url, path, limit)
        return fetch(url, path, limit, function(bytes)
            Importer.space(stage, 0)
            if progress then progress("Downloading preconverted JMdict", bytes) end
        end, 600)
    end
    local code = get("https://api.github.com/repos/" .. Jmdict.repository .. "/releases/tags/" .. Jmdict.tag,
        stage .. "/jmdict-release.json", 512 * 1024)
    assert(code ~= 404, "No preconverted JMdict release is published yet. Use Select preconverted index ZIP with a locally built package.")
    assert(code == 200, "Preconverted JMdict release check failed (HTTP " .. tostring(code) .. ")")
    local file = assert(io.open(stage .. "/jmdict-release.json", "rb"))
    local text = file:read(512 * 1024 + 1); file:close()
    assert(text and #text <= 512 * 1024, "Oversized JMdict release metadata")
    local release = Jmdict.release(JSON.decode(text))
    Importer.space(stage, release.size)
    local source = stage .. "/download.zip"
    assert(get(release.url, source, release.size) == 200, "Preconverted JMdict download failed")
    assert(lfs.attributes(source, "size") == release.size and Importer.hash(source, progress) == release.sha256,
        "JMdict ZIP checksum/size mismatch")
    return source
end

return Jmdict
