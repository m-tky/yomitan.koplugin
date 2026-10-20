local Database = require("yomitan/database")
local Cache = require("yomitan/verificationcache")
local JSON = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")

local Catalog = {}
local verified = {} -- Receipts only; no global connections or document state.

function Catalog.enablePersistentVerification(root)
    Cache.enable(root)
end

local function regular(path)
    return lfs.symlinkattributes(path, "mode") == "file"
end

local function manifest(path, id)
    assert(regular(path .. "/manifest.json"), "Missing or unsafe Yomitan manifest")
    local file = assert(io.open(path .. "/manifest.json", "rb"))
    local text = file:read(65537)
    file:close()
    assert(#text <= 65536, "Oversized Yomitan manifest")
    local data = JSON.decode(text)
    assert(data.schema_version == 1 and data.profile == "ja-terms-v3-text-v1", "Unsupported Yomitan bundle")
    assert(data.content_id == id and type(data.title) == "string", "Yomitan bundle identity mismatch")
    local db = data.files and data.files["dictionary.sqlite3"]
    assert(db and type(db.sha256) == "string" and #db.sha256 == 64 and db.sha256:match("^[a-f0-9]+$"), "Invalid Yomitan database hash")
    assert(type(db.size) == "number" and db.size > 0, "Invalid Yomitan database size")
    return data, sha.sha256(text)
end

local function fingerprint(path, data, manifest_hash)
    local attr = lfs.attributes(path)
    if not attr or not attr.modification or not attr.change or attr.size ~= data.files["dictionary.sqlite3"].size then return end
    for _, suffix in ipairs({"-wal", "-shm", "-journal"}) do
        if lfs.symlinkattributes(path .. suffix) then return end
    end
    return table.concat({data.files["dictionary.sqlite3"].sha256, attr.size, attr.modification, attr.change,
        "", "", manifest_hash}, ":") -- FSP/FUSE device/inode values are not persistent identities.
end

function Catalog.scan(root)
    local entries = {}
    if lfs.attributes(root, "mode") ~= "directory" then return entries end
    for name in lfs.dir(root) do
        if #name == 64 and name:match("^[a-f0-9]+$") and lfs.symlinkattributes(root .. "/" .. name, "mode") == "directory" then
            local path = root .. "/" .. name
            local ok, data = pcall(manifest, path, name)
            entries[#entries + 1] = {id = name, path = path, title = ok and data.title or name,
                manifest = ok and data or nil, error = not ok and tostring(data) or nil}
        end
    end
    table.sort(entries, function(a, b)
        if a.title ~= b.title then return a.title < b.title end
        return a.id < b.id
    end)
    return entries
end

function Catalog.open(item)
    assert(not item.error and item.manifest, item.error or "Invalid Yomitan bundle")
    -- Re-read the manifest: a refresh/activation must not trust an old catalog row.
    local data, manifest_hash = manifest(item.path, item.id)
    local path = item.path .. "/dictionary.sqlite3"
    assert(regular(path), "Missing or unsafe Yomitan database file")
    local attr = assert(lfs.attributes(path))
    local expected = data.files["dictionary.sqlite3"]
    assert(attr.size == expected.size, "Incomplete Yomitan database copy")
    local stamp = fingerprint(path, data, manifest_hash)
    local needs_verification = not stamp or (verified[path] ~= stamp and not Cache.has(item, stamp))
    if needs_verification then
        local file = assert(io.open(path, "rb"))
        local feed = sha.sha256()
        while true do
            local chunk = file:read(256 * 1024)
            if not chunk then break end
            feed(chunk)
        end
        file:close()
        assert(feed() == expected.sha256, "Yomitan database checksum mismatch")
    end
    local db = Database.open(path, item.id)
    local ok, err = pcall(function()
        assert(db.metadata.index.title == data.title and db.metadata.entry_count == data.entry_count,
            "Yomitan manifest/database mismatch")
        if needs_verification then
            assert(db.conn:rowexec("PRAGMA quick_check") == "ok", "Corrupt Yomitan database")
        end
        local current, current_hash = manifest(item.path, item.id)
        assert(fingerprint(path, current, current_hash) == stamp, "Dictionary changed during verification")
        if stamp then
            verified[path] = stamp
            Cache.put(item, stamp) -- Also normalizes a reusable older receipt.
        end
    end)
    if not ok then db:close(); error(err) end
    return db
end

-- Only the setup supervisor may call this with a proof returned by its own
-- finished worker, after private staging publication. Never trust a manifest
-- alone as a verification proof. This avoids rehashing a large import in the UI.
function Catalog.rememberVerified(item, proof)
    local data, manifest_hash = manifest(item.path, item.id)
    local path = item.path .. "/dictionary.sqlite3"
    assert(regular(path), "Missing imported dictionary database")
    local attr = assert(lfs.attributes(path))
    local expected = data.files["dictionary.sqlite3"]
    assert(type(proof) == "table" and proof.id == item.id and proof.sha256 == expected.sha256
        and proof.size == expected.size and attr.size == proof.size
        and proof.modification ~= nil and proof.change ~= nil
        and attr.modification == proof.modification and attr.change == proof.change,
        "Imported dictionary changed after worker verification")
    assert(not proof.manifest_sha256 or proof.manifest_sha256 == manifest_hash, "Imported manifest changed after worker verification")
    local stamp = fingerprint(path, data, manifest_hash)
    if stamp then verified[path] = stamp; Cache.put(item, stamp) end
end

function Catalog.isVerified(item)
    if not item or item.error then return false end
    local ok, result = pcall(function()
        local data, manifest_hash = manifest(item.path, item.id)
        local path = item.path .. "/dictionary.sqlite3"
        if not regular(path) then return false end
        local stamp = fingerprint(path, data, manifest_hash)
        return stamp ~= nil and (verified[path] == stamp or Cache.has(item, stamp))
    end)
    return ok and not not result
end

function Catalog.invalidate()
    verified = {}
end

return Catalog
