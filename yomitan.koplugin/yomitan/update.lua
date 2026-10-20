-- Release validation and staged publication shared by the built-in updater and
-- release tests. No downloaded Lua is evaluated before user-approved installation.
local JSON = require("rapidjson")
local Importer = require("yomitan/importer")
local Parser = require("yomitan/jsonstream")
local Zip = require("yomitan/zipreader")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local Update = {repository = "m-tky/yomitan.koplugin", asset_name = "yomitan.koplugin.zip"}
local ROOT = "yomitan.koplugin/"
local REQUIRED = {"main.lua", "_meta.lua", "import.lua", "update-worker.lua", "LICENSE",
    "yomitan/update.lua", "yomitan/update_ui.lua", "yomitan/update_net.lua", "yomitan/automatic.lua",
    "yomitan/search.lua", "yomitan/transformer.lua", "yomitan/yomitan-transforms.json", "yomitan/database.lua",
    "yomitan/catalog.lua", "yomitan/verificationcache.lua", "yomitan/setup.lua", "yomitan/importjob.lua",
    "yomitan/importer.lua", "yomitan/jsonstream.lua", "yomitan/zipreader.lua", "yomitan/jmdict.lua", "yomitan/bundle.lua"}

function Update.version(text)
    assert(type(text) == "string", "Missing plugin version")
    local a, b, c = text:match("^v?(%d+)%.(%d+)%.(%d+)$")
    assert(a and #a <= 6 and #b <= 6 and #c <= 6, "Only stable semantic versions are supported")
    for _, part in ipairs({a,b,c}) do assert(#part == 1 or part:sub(1,1) ~= "0", "Invalid version component") end
    return {tonumber(a), tonumber(b), tonumber(c)}, a .. "." .. b .. "." .. c
end

function Update.newer(remote, current)
    local a, b = Update.version(remote), Update.version(current)
    for i = 1, 3 do if a[i] ~= b[i] then return a[i] > b[i] end end
    return false
end

local function decodeFile(path, maximum)
    local file = assert(io.open(path, "rb"))
    local text = file:read(maximum + 1); file:close()
    assert(text and #text <= maximum, "Oversized update metadata")
    return Parser.new((function()
        local done = false
        return function() if not done then done = true; return text end end
    end)(), maximum):one()
end

function Update.release(data)
    assert(type(data) == "table" and not data.draft and not data.prerelease, "A stable GitHub release is required")
    local _, version = Update.version(data.tag_name)
    local prefix = "https://github.com/" .. Update.repository .. "/releases/download/" .. data.tag_name .. "/"
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == Update.asset_name then
            assert(asset.browser_download_url == prefix .. Update.asset_name, "Unexpected plugin download URL")
            local hash = type(asset.digest) == "string" and asset.digest:match("^sha256:([a-f0-9]+)$")
            assert(hash and #hash == 64, "The release must publish its SHA-256 asset digest")
            assert(type(asset.size) == "number" and asset.size > 0 and asset.size <= 8 * 1024^2 and asset.size % 1 == 0,
                "Invalid plugin archive size")
            return {version = version, tag = data.tag_name, url = asset.browser_download_url, sha256 = hash, size = asset.size}
        end
    end
    error("This release has no compatible Yomitan plugin ZIP")
end

function Update.check(stage, current, fetch)
    Update.version(current)
    local path = stage .. "/release.json"
    local code = fetch("https://api.github.com/repos/" .. Update.repository .. "/releases/latest", path, 512 * 1024)
    if code == 404 then return {status = "prepared", kind = "check", available = false, unpublished = true} end
    assert(code == 200, "GitHub update check failed (HTTP " .. tostring(code) .. ")")
    local release = Update.release(decodeFile(path, 512 * 1024))
    return {status = "prepared", kind = "check", available = Update.newer(release.version, current), release = release}
end

local function allowed(path)
    return path == "main.lua" or path == "_meta.lua" or path == "import.lua" or path == "update-worker.lua"
        or path == "README.md" or path == "LICENSE" or path == "plugin.json"
        or path:match("^yomitan/[%w_%-]+%.lua$") or path == "yomitan/yomitan-transforms.json"
end

local function readMember(zip, member, limit)
    local read = zip:stream(member, limit)
    local parts = {}
    while true do local part = read(); if not part then break end; parts[#parts + 1] = part end
    return table.concat(parts)
end

function Update.prepare(stage, release, fetch)
    local checked = Update.release{tag_name = release.tag, assets = {{name = Update.asset_name,
        browser_download_url = release.url, digest = "sha256:" .. release.sha256, size = release.size}}}
    assert(checked.version == release.version, "Release version mismatch")
    local archive = stage .. "/download.zip"
    assert(fetch(release.url, archive, 8 * 1024^2) == 200, "Plugin download failed")
    assert(lfs.attributes(archive, "size") == release.size and Importer.hash(archive) == release.sha256, "Plugin ZIP checksum/size mismatch")
    local zip = Zip.open(archive)
    local ok, result = pcall(function()
        local manifest_text = readMember(zip, assert(zip.members[ROOT .. "plugin.json"], "Missing package manifest"), 65536)
        local manifest = JSON.decode(manifest_text)
        assert(type(manifest) == "table" and manifest.format == 1 and manifest.plugin_id == "yomitan"
            and manifest.version == release.version and manifest.provider_api == 1 and type(manifest.files) == "table", "Incompatible plugin package")
        local count, total = 0, 0
        for path, info in pairs(manifest.files) do
            assert(type(path) == "string" and path ~= "plugin.json" and allowed(path), "Unexpected plugin file")
            assert(type(info) == "table" and type(info.sha256) == "string" and #info.sha256 == 64
                and info.sha256:match("^[a-f0-9]+$") and type(info.size) == "number" and info.size >= 0, "Invalid package file hash/size")
            local member = assert(zip.members[ROOT .. path], "Missing package file")
            assert(member.size == info.size and info.size <= 2 * 1024^2, "Oversized package file")
            count, total = count + 1, total + info.size
        end
        assert(count <= 128 and total <= 16 * 1024^2, "Plugin package limits exceeded")
        for name in pairs(zip.members) do
            local relative = name:sub(#ROOT + 1)
            assert(name:sub(1, #ROOT) == ROOT and (relative == "plugin.json" or manifest.files[relative]), "Unlisted archive member")
        end
        for _, path in ipairs(REQUIRED) do assert(manifest.files[path], "Incomplete plugin package: " .. path) end
        local candidate = stage .. "/candidate"
        assert(lfs.mkdir(candidate)); assert(lfs.mkdir(candidate .. "/yomitan"))
        for path, info in pairs(manifest.files) do
            local text = readMember(zip, zip.members[ROOT .. path], 2 * 1024^2)
            assert(sha.sha256(text) == info.sha256, "Package file checksum mismatch")
            if path:match("%.lua$") then
                assert(text:byte(1) ~= 27 and loadstring(text, "@" .. path), "Invalid or binary Lua in plugin package")
            end
            if path == "_meta.lua" then
                assert(text:match('version%s*=%s*["\']([^"\']+)["\']') == release.version, "Plugin metadata version mismatch")
            end
            local file = assert(io.open(candidate .. "/" .. path, "wb")); assert(file:write(text)); assert(file:close())
        end
        local file = assert(io.open(candidate .. "/plugin.json", "wb")); assert(file:write(manifest_text)); assert(file:close())
        return {status = "prepared", kind = "install", version = release.version}
    end)
    zip:close()
    assert(ok, result)
    return result
end

-- Only remove this supervisor's private stage, without traversing any symlink.
function Update.cleanup(stage)
    local remaining = 160
    local function remove(path, depth)
        if not lfs.symlinkattributes(path) then return true end
        remaining = remaining - 1
        if remaining < 0 or depth > 4 then return false end
        if lfs.symlinkattributes(path, "mode") ~= "directory" then return os.remove(path) ~= nil end
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." and not remove(path .. "/" .. name, depth + 1) then return false end
        end
        return lfs.rmdir(path) ~= nil
    end
    return remove(stage, 0)
end

function Update.publish(stage, target, rename)
    rename = rename or os.rename
    assert(target:match("/yomitan%.koplugin$") and lfs.symlinkattributes(target, "mode") == "directory", "Unsafe plugin installation path")
    local candidate = stage .. "/candidate"
    local manifest = decodeFile(candidate .. "/plugin.json", 65536)
    assert(manifest.plugin_id == "yomitan" and manifest.provider_api == 1, "Incompatible staged package")
    for path, info in pairs(manifest.files) do
        assert(allowed(path) and lfs.symlinkattributes(candidate .. "/" .. path, "mode") == "file", "Unsafe staged plugin file")
        assert(lfs.attributes(candidate .. "/" .. path, "size") == info.size and Importer.hash(candidate .. "/" .. path) == info.sha256,
            "Staged plugin changed after verification")
    end
    local backup = stage .. "-backup"
    assert(not lfs.symlinkattributes(backup) and lfs.mkdir(backup), "Unable to create plugin backup")
    assert(rename(target, backup .. "/yomitan.koplugin"), "Unable to back up the installed plugin")
    local ok, err = rename(candidate, target)
    if not ok then
        assert(rename(backup .. "/yomitan.koplugin", target), "Publication failed; restore the plugin backup at " .. backup)
        lfs.rmdir(backup)
        error("Plugin installation failed; previous version restored: " .. tostring(err))
    end
    return backup
end

return Update
