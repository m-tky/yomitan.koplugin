-- Shared immutable-bundle hashing, space checks and verification. No dictionary conversion.
local Catalog = require("yomitan/catalog")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local Importer = {}

function Importer.hash(path, progress)
    local attr = assert(lfs.attributes(path), "Missing input file")
    assert(attr.mode == "file", "Input must be a regular file")
    local file = assert(io.open(path, "rb"))
    local ok, digest = pcall(function()
        local feed, bytes = sha.sha256(), 0
        while true do
            local chunk = file:read(65536)
            if not chunk then break end
            bytes = bytes + #chunk
            assert(bytes <= attr.size, "File grew while checksumming")
            feed(chunk)
            if progress then progress("Checksumming files", bytes) end
        end
        assert(bytes == attr.size, "File changed or failed while checksumming")
        return feed()
    end)
    file:close()
    assert(ok, digest)
    return digest
end

function Importer.space(path, payload, available_fn)
    local _, _, available = (available_fn or ffiUtil.df)(path)
    assert(type(available) == "number", "Unable to check free space for index installation")
    assert(available >= 24 * 1024^2 + (payload or 0), "Not enough free space (24 MiB reserve required)")
end

function Importer.proof(path, manifest)
    local attr = assert(lfs.attributes(path .. "/dictionary.sqlite3"))
    return {id = manifest.content_id, sha256 = manifest.files["dictionary.sqlite3"].sha256,
        size = attr.size, modification = attr.modification, change = attr.change,
        manifest_sha256 = Importer.hash(path .. "/manifest.json")}
end

function Importer.verify(root, ids, progress)
    local by_id, proofs = {}, {}
    for _, item in ipairs(Catalog.scan(root)) do by_id[item.id] = item end
    assert(type(ids) == "table" and #ids <= 8, "Invalid enabled dictionary list")
    for _, id in ipairs(ids) do
        assert(by_id[id], "An enabled dictionary is missing")
        if progress then progress("Verifying installed dictionaries", #proofs) end
        local db = Catalog.open(by_id[id])
        db:close()
        proofs[#proofs + 1] = Importer.proof(by_id[id].path, by_id[id].manifest)
    end
    return proofs
end

return Importer
