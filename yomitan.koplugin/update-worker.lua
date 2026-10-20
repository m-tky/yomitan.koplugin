-- Fresh-process plugin updater. Downloads/stages only; the parent publishes.
require("setupkoenv")
local _, stage, _, plugin_root, mode, payload = unpack(arg)
package.path = plugin_root .. "/?.lua;" .. package.path
local JSON = require("rapidjson")
local Update = require("yomitan/update")
local Net = require("yomitan/update_net")
local function write(name, value)
    local path = stage .. "/" .. name
    local file = assert(io.open(path .. ".tmp", "wb")); assert(file:write(assert(JSON.encode(value)))); assert(file:close())
    assert(os.rename(path .. ".tmp", path))
end
local ok, result = pcall(function()
    local request = assert(JSON.decode(payload))
    write("progress.json", {phase = mode == "check-update" and "Checking GitHub releases" or "Downloading and verifying plugin", amount = ""})
    if mode == "check-update" then return Update.check(stage, request.current, Net.fetch) end
    assert(mode == "install-update", "Unknown plugin update operation")
    return Update.prepare(stage, request.release, Net.fetch)
end)
if not ok then result = {status = "error", message = tostring(result):sub(1, 4096)} end
write("result.json", result)
