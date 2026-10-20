-- Standalone worker entry point, executed by KOReader's bundled LuaJIT.
-- Never initialize Device/UI or touch reader settings in this fresh process.
require("setupkoenv")
local source, stage, root, plugin_root, mode, ids_json = unpack(arg)
package.path = plugin_root .. "/?.lua;" .. package.path
local JSON = require("rapidjson")
local Importer = require("yomitan/importer")
require("yomitan/catalog").enablePersistentVerification(root)

local last_phase, last_time
local function write(name, data)
    local path = stage .. "/" .. name
    local file = assert(io.open(path .. ".tmp", "wb"))
    assert(file:write(assert(JSON.encode(data))))
    assert(file:close())
    assert(os.rename(path .. ".tmp", path))
end
local function progress(phase, amount)
    local now = os.time()
    if last_time == nil or now ~= last_time or (phase == "Finalizing and checking SQLite" and phase ~= last_phase) then
        write("progress.json", {phase = phase, amount = amount})
        last_phase, last_time = phase, now
    end
end
local ok, result = pcall(function()
    local ids = assert(JSON.decode(ids_json))
    local imported
    if mode == "download-jmdict" then source = require("yomitan/jmdict").download(stage, progress) end
    if mode == "import" or mode == "download-jmdict" then imported = require("yomitan/bundle").prepare(source, stage, root, progress)
    else assert(mode == "verify", "Unknown setup operation") end
    local proofs = Importer.verify(root, ids, progress)
    if imported then
        local seen = false
        for _, proof in ipairs(proofs) do if proof.id == imported.id then seen = true end end
        if not seen then proofs[#proofs + 1] = imported.proof end
        return {status = imported.status, id = imported.id, proofs = proofs}
    end
    return {status = "verified", proofs = proofs}
end)
if not ok then result = {status = "error", message = tostring(result):sub(1, 4096)} end
write("result.json", result)
