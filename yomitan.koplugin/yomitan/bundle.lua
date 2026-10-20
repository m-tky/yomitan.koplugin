-- Install preconverted SQLite packages only. Never interpret a term ZIP or execute SQL from it.
local Database = require("yomitan/database")
local Importer = require("yomitan/importer")
local Parser = require("yomitan/jsonstream")
local Zip = require("yomitan/zipreader")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local Bundle = {max_archive = 128 * 1024^2}
local PREFIX = "jmdict-index/"
local PROFILE = "ja-terms-v3-text-v1"
local documents = {['SOURCES.txt']=65536, ['JMdict-LICENSE.txt']=256*1024,
    ['JMdict-documentation.html']=256*1024, ['JMdict-index.json']=1024*1024, ['README.txt']=65536}

local function decode(text, maximum)
    local done = false
    return Parser.new(function() if not done then done = true; return text end end, maximum):one()
end

local function read(zip, name, limit)
    local stream = zip:stream(assert(zip.members[name], "Missing package file: " .. name), limit)
    local parts = {}
    while true do local part = stream(); if not part then break end; parts[#parts + 1] = part end
    return table.concat(parts)
end

local function integer(value, maximum)
    return type(value) == "number" and value > 0 and value <= maximum and value % 1 == 0
end
local function hash(value)
    return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$")
end

function Bundle.prepare(source, stage, root, progress, available_fn)
    assert(lfs.symlinkattributes(source, "mode") == "file", "Package must be a regular ZIP")
    assert(lfs.attributes(source, "size") <= Bundle.max_archive, "Preconverted package exceeds its size limit")
    Importer.space(stage, 0, available_fn)
    local zip = Zip.open(source)
    local ok, result = pcall(function()
        assert(zip.members[PREFIX .. "package.json"], "Select a preconverted index ZIP. Raw Yomitan term ZIPs are no longer supported.")
        local descriptor_text = read(zip, PREFIX .. "package.json", 65536)
        local descriptor = decode(descriptor_text, 65536)
        assert(type(descriptor) == "table" and descriptor.format == 1 and descriptor.kind == "jmdict-sqlite-index"
            and descriptor.profile == PROFILE and descriptor.converter_version == 1 and hash(descriptor.content_id)
            and integer(descriptor.entry_count, 5000000) and type(descriptor.files) == "table", "Unsupported preconverted index package")
        local origin = descriptor.source
        assert(type(origin) == "table" and type(origin.tag) == "string" and origin.tag:match("^%d%d%d%d%-%d%d%-%d%d$")
            and origin.url == "https://github.com/yomidevs/jmdict-yomitan/releases/download/" .. origin.tag .. "/JMdict_english.zip"
            and hash(origin.sha256) and integer(origin.size, 64 * 1024^2), "Invalid dictionary source provenance")
        local id = descriptor.content_id
        local allowed = {[id .. "/dictionary.sqlite3"]=512*1024^2, [id .. "/manifest.json"]=65536}
        for name, limit in pairs(documents) do allowed[name] = limit end
        local count, total = 0, 0
        for name, info in pairs(descriptor.files) do
            assert(type(name) == "string" and allowed[name], "Unexpected package file")
            assert(type(info) == "table" and hash(info.sha256) and integer(info.size, allowed[name]), "Invalid package file size/hash")
            local member = assert(zip.members[PREFIX .. name], "Missing package member")
            assert(member.size == info.size, "Package member size mismatch")
            count, total = count + 1, total + info.size
        end
        assert(count == 7, "Incomplete index package")
        for name in pairs(allowed) do assert(descriptor.files[name], "Missing required index file: " .. name) end
        count = 0
        for name in pairs(zip.members) do
            local relative = name:sub(#PREFIX + 1)
            assert(name:sub(1, #PREFIX) == PREFIX and (relative == "package.json" or descriptor.files[relative]), "Undeclared ZIP member")
            count = count + 1
        end
        assert(count == 8, "Unexpected index archive layout")
        Importer.space(stage, total, available_fn)
        local bundle = stage .. "/bundle"
        assert(lfs.mkdir(bundle), "Unable to create private index staging directory")
        for name, info in pairs(descriptor.files) do
            local target = bundle .. "/" .. (name == id .. "/dictionary.sqlite3" and "dictionary.sqlite3"
                or name == id .. "/manifest.json" and "manifest.json" or name)
            local output = assert(io.open(target, "wb"))
            local success, err = pcall(function()
                local feed, bytes = sha.sha256(), 0
                local stream = zip:stream(zip.members[PREFIX .. name], allowed[name])
                while true do
                    local part = stream(); if not part then break end
                    bytes = bytes + #part
                    feed(part); assert(output:write(part))
                    if bytes % (1024*1024) < #part then Importer.space(stage, 0, available_fn) end
                    if progress then progress("Extracting and verifying " .. (name:match("[^/]+$") or name), bytes) end
                end
                assert(bytes == info.size and feed() == info.sha256, "Package file checksum mismatch")
            end)
            local closed = output:close()
            assert(success, err); assert(closed, "Unable to finalize index file")
        end
        local output = assert(io.open(bundle .. "/package.json", "wb"))
        assert(output:write(descriptor_text)); assert(output:close())
        local manifest = decode(read(zip, PREFIX .. id .. "/manifest.json", 65536), 65536)
        local db_info = descriptor.files[id .. "/dictionary.sqlite3"]
        assert(type(manifest) == "table" and manifest.content_id == id and manifest.schema_version == 1
            and manifest.converter_version == 1 and manifest.profile == PROFILE and manifest.archive_sha256 == origin.sha256
            and manifest.entry_count == descriptor.entry_count and type(manifest.title) == "string"
            and type(manifest.files) == "table" and type(manifest.files['dictionary.sqlite3']) == "table"
            and manifest.files['dictionary.sqlite3'].sha256 == db_info.sha256
            and manifest.files['dictionary.sqlite3'].size == db_info.size, "Package/manifest mismatch")
        if progress then progress("Checking SQLite index", descriptor.entry_count) end
        local db = Database.open(bundle .. "/dictionary.sqlite3", id)
        local valid, err = pcall(function()
            assert(db.metadata.index.title == manifest.title and db.metadata.entry_count == manifest.entry_count,
                "Package/database metadata mismatch")
            assert(db.conn:rowexec("PRAGMA quick_check") == "ok", "Corrupt SQLite index")
            assert(db.conn:rowexec("PRAGMA foreign_key_check") == nil, "Invalid SQLite index references")
        end)
        db:close(); assert(valid, err)
        local proof = Importer.proof(bundle, manifest)
        if lfs.symlinkattributes(root .. "/" .. id) then
            local proofs = Importer.verify(root, {id}, progress)
            return {status = "existing", id = id, proof = proofs[1]}
        end
        return {status = "prepared", id = id, proof = proof}
    end)
    zip:close()
    assert(ok, result)
    return result
end

return Bundle
