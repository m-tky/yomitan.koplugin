-- Automatic index choice and non-blocking verification. Never supplies definitions.
local Catalog = require("yomitan/catalog")
local InfoMessage = require("ui/widget/infomessage")
local Job = require("yomitan/importjob")
local UIManager = require("ui/uimanager")
local Automatic = {}
local FIXTURE = "Original Yomitan regression fixture"

function Automatic.select(catalog, configured)
    local valid, best = {}, nil
    for _, item in ipairs(catalog) do
        if not item.error then
            valid[item.id] = item
            if item.title:match("^JMdict %[") and (not best or item.title > best.title) then best = item end
        end
    end
    if best then return {best.id} end
    for _, id in ipairs(type(configured) == "table" and configured or {}) do
        if valid[id] and valid[id].title ~= FIXTURE then return {id} end
    end
    for _, item in ipairs(catalog) do
        if not item.error and item.title ~= FIXTURE then return {item.id} end
    end
    -- Preserve explicit synthetic QA use only when no real index is installed.
    for _, item in ipairs(catalog) do if not item.error then return {item.id} end end
    return {}
end

local function notice(plugin, text)
    if plugin:isEnabled() then
        UIManager:show(InfoMessage:new{text = text, timeout = 3})
    end
end

function Automatic.start(plugin)
    if plugin.setup_closed or plugin.setup_job or plugin.automatic_disabled
            or not plugin:isEnabled() then return end
    Catalog.enablePersistentVerification(plugin.root)
    local catalog, by_id = Catalog.scan(plugin.root), {}
    for _, item in ipairs(catalog) do by_id[item.id] = item end
    local ids = plugin:selectedIds(catalog)
    if #ids == 0 then return end
    local ready = true
    for _, id in ipairs(ids) do if not Catalog.isVerified(by_id[id]) then ready = false end end
    if ready then
        G_reader_settings:saveSetting("yomitan_dictionary_ids", ids)
        plugin.automatic_failed = nil
        return
    end
    plugin:closeDatabases()
    plugin.automatic_verifying, plugin.automatic_failed = true, nil
    local function clear()
        plugin.setup_job = nil
        plugin.automatic_verifying = nil
    end
    local function failed(err)
        clear()
        plugin.automatic_failed = true
        require("logger").warn("Yomitan automatic verification:", err)
        notice(plugin, "Yomitan unavailable. Dictionary lookup still works.")
    end
    local ok, job = pcall(Job.start, plugin.root, plugin.path, "", "verify", ids, {
        background = true,
        done = function(result)
            clear()
            if plugin.setup_closed then return end
            local proofs = {}
            for _, proof in ipairs(result.proofs or {}) do proofs[proof.id] = proof end
            local current = {}
            for _, item in ipairs(Catalog.scan(plugin.root)) do current[item.id] = item end
            for _, id in ipairs(ids) do
                assert(current[id] and proofs[id], "Missing automatic verification proof")
                Catalog.rememberVerified(current[id], proofs[id])
            end
            local chosen = plugin:selectedIds(Catalog.scan(plugin.root))
            if table.concat(chosen, ":") == table.concat(ids, ":") then
                G_reader_settings:saveSetting("yomitan_dictionary_ids", ids)
            end
            notice(plugin, "Yomitan ready.")
        end,
        error = failed,
        cancelled = function()
            clear()
            if not plugin.setup_closed then Automatic.start(plugin) end
        end,
    })
    if ok then
        plugin.setup_job = job
        notice(plugin, "Preparing Yomitan…")
    else failed(job) end
end

return Automatic
