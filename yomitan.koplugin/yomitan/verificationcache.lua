-- Local verification receipts for immutable SQLite bundles. These are not
-- authenticity signatures or protection against an attacker forging local files.
-- Bump VERSION when changing the full-verification contract.
local JSON = require("rapidjson")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
require("ffi/posix_h")
local Cache = {}
local VERSION = 1
local NAME = "/.verification-v1.json"
local roots = {}

local function normalize(root)
    return root:gsub("/+$", ""):gsub("^%./", "")
end

function Cache.enable(root)
    roots[normalize(root)] = true
end

local function location(item)
    local root = item.path:match("^(.*)/[^/]+$")
    if root and roots[normalize(root)] then return root .. NAME end
end

local function load(path)
    if lfs.symlinkattributes(path, "mode") ~= "file" then return {} end
    local file = io.open(path, "rb")
    if not file then return {} end
    local text = file:read(65537)
    file:close()
    if not text or #text > 65536 then return {} end
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" or data.version ~= VERSION or type(data.entries) ~= "table" then return {} end
    local entries, count = {}, 0
    for id, stamp in pairs(data.entries) do
        if type(id) ~= "string" or #id ~= 64 or not id:match("^[a-f0-9]+$")
                or type(stamp) ~= "string" or #stamp > 512 then return {} end
        count = count + 1
        if count > 128 then return {} end
        entries[id] = stamp
    end
    return entries
end

-- Kindle's FSP/FUSE device/inode identifiers can change without a file change.
-- Ignore those transient fields, including in receipts from the first version.
-- Identity is the immutable bundle ID plus hashes, size and modification/change times.
local function stable(stamp)
    if type(stamp) ~= "string" then return end
    local hash, size, modification, change, manifest = stamp:match("^([^:]+):([^:]+):([^:]+):([^:]+):[^:]*:[^:]*:([^:]+)$")
    if hash then return table.concat({hash, size, modification, change, manifest}, ":") end
end

function Cache.has(item, stamp)
    local path = location(item)
    local expected = stable(stamp)
    return path ~= nil and expected ~= nil and stable(load(path)[item.id]) == expected
end

function Cache.put(item, stamp)
    local path = location(item)
    if not path or not stamp then return end
    local temporary = path .. ".tmp." .. tonumber(ffi.C.getpid())
    local ok, err = pcall(function()
        local entries = load(path)
        if entries[item.id] == stamp then return end
        local count = 0
        for _ in pairs(entries) do count = count + 1 end
        if count >= 128 and not entries[item.id] then entries = {} end
        entries[item.id] = stamp
        assert(not lfs.symlinkattributes(temporary), "Unexpected verification cache temporary file")
        local file = assert(io.open(temporary, "wb"))
        local written, message = file:write(assert(JSON.encode({version = VERSION, entries = entries})))
        local closed = file:close()
        assert(written and closed, message or "Unable to write verification cache")
        assert(os.rename(temporary, path))
    end)
    if not ok then
        -- Cache failure must not invalidate a successfully verified dictionary.
        if lfs.symlinkattributes(temporary, "mode") == "file" then os.remove(temporary) end
        require("logger").warn("Yomitan verification cache was not saved:", err)
    end
end

return Cache
