local ButtonDialog = require("ui/widget/buttondialog")
local Catalog = require("yomitan/catalog")
local InfoMessage = require("ui/widget/infomessage")
local Job = require("yomitan/importjob")
local Jmdict = require("yomitan/jmdict")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local Setup = {}

local function message(plugin, text)
    if not plugin.setup_closed then UIManager:show(InfoMessage:new{text = text}) end
end

local function installed(plugin, fallback)
    local catalog, valid = Catalog.scan(plugin.root), {}
    for _, item in ipairs(catalog) do if not item.error then valid[item.id] = true end end
    local ids, seen = {}, {}
    for _, id in ipairs(plugin:selectedIds(catalog)) do
        if valid[id] and not seen[id] and #ids < 8 then ids[#ids + 1], seen[id] = id, true end
    end
    if fallback and #ids == 0 then
        for _, item in ipairs(catalog) do if not item.error then ids[1] = item.id; break end end
    end
    return ids
end

function Setup.complete(plugin, ids)
    -- Called only after an explicit final confirmation and worker validation.
    assert(not plugin.setup_closed and #ids > 0 and #ids <= 8, "Invalid setup activation")
    local by_id = {}
    for _, item in ipairs(Catalog.scan(plugin.root)) do by_id[item.id] = item end
    for _, id in ipairs(ids) do
        assert(by_id[id] and plugin.setup_proofs and plugin.setup_proofs[id], "Dictionary is no longer verified")
        Catalog.rememberVerified(by_id[id], plugin.setup_proofs[id])
    end
    plugin.automatic_failed = nil
    plugin:closeDatabases()
    G_reader_settings:saveSetting("yomitan_dictionary_ids", ids)
    G_reader_settings:saveSetting("dictionary_provider", plugin.provider_id)
    if G_reader_settings:isTrue("external_dict_lookup") then G_reader_settings:saveSetting("external_dict_lookup", false) end
    G_reader_settings:saveSetting("yomitan_setup_version", 1)
    G_reader_settings:delSetting("yomitan_setup_deferred")
    plugin.setup_proofs = nil
end

function Setup.confirm(plugin, ids)
    if plugin.setup_closed then return end
    local external = G_reader_settings:isTrue("external_dict_lookup")
        and "\n" .. _("External lookup will be turned off for all books.") or ""
    local dialog
    local function close()
        UIManager:close(dialog)
        plugin.setup_dialog = nil
    end
    local function enable()
        close()
        local ok, err = pcall(Setup.complete, plugin, ids)
        message(plugin, ok and _("Yomitan enabled.") or (_("Unable to enable Yomitan.") .. "\n" .. tostring(err)))
    end
    dialog = ButtonDialog:new{
        title = (#ids <= 8 and _("Index ready. Enable Yomitan?") or _("Too many indexes (maximum 8).")) .. external,
        dismissable = false,
        buttons = {
            {{text = _("Enable"), enabled = #ids > 0 and #ids <= 8, callback = enable}},
            {{text = _("Not now"), callback = function()
                close()
                G_reader_settings:saveSetting("yomitan_setup_version", 1)
                G_reader_settings:delSetting("yomitan_setup_deferred")
                plugin.setup_proofs = nil
            end}},
        },
    }
    plugin.setup_dialog = dialog
    UIManager:show(dialog)
end

function Setup.accept(plugin, result, stage, previous_ids)
    assert(not plugin.setup_closed, "Reader closed during setup")
    local id = result.id
    if id then assert(type(id) == "string" and #id == 64 and id:match("^[a-f0-9]+$"), "Invalid worker dictionary ID") end
    if result.status == "prepared" then
        local manifest = Job.read(stage .. "/bundle/manifest.json")
        assert(manifest and manifest.content_id == id, "Worker manifest mismatch")
        assert(not lfs.symlinkattributes(plugin.root .. "/" .. id), "Dictionary appeared during import; use installed dictionaries instead")
        assert(os.rename(stage .. "/bundle", plugin.root .. "/" .. id))
    end
    local by_id = {}
    for _, item in ipairs(Catalog.scan(plugin.root)) do by_id[item.id] = item end
    assert(type(result.proofs) == "table" and #result.proofs > 0 and #result.proofs <= 9, "Missing worker verification proofs")
    local proofs = {}
    for _, proof in ipairs(result.proofs) do
        assert(by_id[proof.id] and not proofs[proof.id], "Invalid verified dictionary selection")
        Catalog.rememberVerified(by_id[proof.id], proof)
        proofs[proof.id] = proof
    end
    local ids, seen = {}, {}
    for _, previous in ipairs(previous_ids) do
        assert(proofs[previous], "Existing dictionary was not verified")
        ids[#ids + 1], seen[previous] = previous, true
    end
    if id and not seen[id] then assert(proofs[id], "Imported dictionary was not verified"); ids[#ids + 1] = id end
    assert(#ids > 0, "No verified dictionaries")
    plugin.setup_proofs = proofs
    Setup.confirm(plugin, ids)
end

function Setup.start(plugin, source, mode)
    if plugin.setup_closed or plugin.setup_job then return end
    if not plugin.compatible then message(plugin, _("This KOReader build is not supported.")); return end
    util.makePath(plugin.root)
    Job.recover(plugin.root)
    local ids = installed(plugin, mode == "verify")
    if mode == "verify" and #ids == 0 then message(plugin, _("No index installed. Download JMdict or select an index ZIP.")); return end
    G_reader_settings:saveSetting("yomitan_setup_deferred", true)
    plugin:closeDatabases()
    local ok, job = pcall(Job.start, plugin.root, plugin.path, source, mode, ids, {
        done = function(result, stage)
            plugin.setup_job = nil
            Setup.accept(plugin, result, stage, ids)
        end,
        error = function(err)
            plugin.setup_job = nil
            message(plugin, _("Yomitan setup failed.") .. "\n\n" .. err)
        end,
        cancelled = function()
            plugin.setup_job = nil
            message(plugin, _("Yomitan setup cancelled."))
        end,
    })
    if ok then plugin.setup_job = job else message(plugin, tostring(job)) end
end

function Setup.download(plugin)
    if plugin.setup_closed or plugin.setup_job or plugin.setup_dialog then return end
    local dialog
    local function close() UIManager:close(dialog); plugin.setup_dialog = nil end
    dialog = ButtonDialog:new{
        title = _("Download JMdict from GitHub?") .. "\nJim Breen / EDRDG · CC BY-SA 4.0",
        dismissable = false,
        buttons = {
            {{text = _("Sources and licence"), callback = function()
                UIManager:show(require("ui/widget/textviewer"):new{
                    title = _("JMdict sources and licence"), text = Jmdict.notice})
            end}},
            {{text = _("Agree and download"), callback = function() close(); Setup.start(plugin, "", "download-jmdict") end}},
            {{text = _("Cancel"), callback = close}},
        },
    }
    plugin.setup_dialog = dialog
    UIManager:show(dialog)
end

function Setup.choose(plugin)
    local chooser = PathChooser:new{
        title = _("Long-press a preconverted index ZIP"),
        path = plugin.ui and plugin.ui.document and plugin.ui.document.file
            and util.splitFilePathName(plugin.ui.document.file) or nil,
        select_file = true, select_directory = false,
        close_callback = function() plugin.setup_chooser = nil end,
        file_filter = function(name) return name:lower():match("%.zip$") ~= nil end,
        onConfirm = function(path)
            plugin.setup_chooser = nil
            -- PathChooser closes its own widgets after onConfirm returns.
            plugin.setup_scheduled = function()
                plugin.setup_scheduled = nil
                if not plugin.setup_closed then Setup.start(plugin, path, "import") end
            end
            UIManager:nextTick(plugin.setup_scheduled)
        end,
    }
    plugin.setup_chooser = chooser
    UIManager:show(chooser)
end

function Setup.show(plugin)
    if plugin.setup_closed or plugin.setup_job or plugin.setup_dialog or plugin.setup_chooser then return end
    if not plugin.compatible then message(plugin, _("This KOReader build is not supported.")); return end
    local ok, err = pcall(function() util.makePath(plugin.root); Job.recover(plugin.root) end)
    if not ok then message(plugin, tostring(err)); return end
    local dialog
    local function close()
        UIManager:close(dialog)
        plugin.setup_dialog = nil
    end
    dialog = ButtonDialog:new{
        title = _("Yomitan setup") .. "\n" .. _("Download a Japanese search index. Definitions come from StarDict."),
        dismissable = false,
        buttons = {
            {{text = _("Select preconverted index ZIP"), callback = function()
                close(); G_reader_settings:saveSetting("yomitan_setup_deferred", true); Setup.choose(plugin)
            end}},
            {{text = _("Use installed dictionaries"), callback = function()
                close(); Setup.start(plugin, "", "verify")
            end}},
            {{text = _("Later"), callback = function()
                close(); G_reader_settings:saveSetting("yomitan_setup_deferred", true)
            end}},
            {{text = _("Download/update JMdict"), callback = function() close(); Setup.download(plugin) end}},
        },
    }
    plugin.setup_dialog = dialog
    UIManager:show(dialog)
end

function Setup.recover(plugin)
    local ok, err = pcall(Job.recover, plugin.root)
    if not ok then require("logger").warn("Yomitan staging recovery:", err) end
end

function Setup.auto(plugin)
    if G_reader_settings:readSetting("yomitan_setup_version") == 1 or G_reader_settings:isTrue("yomitan_setup_deferred") then return end
    plugin.setup_scheduled = function()
        plugin.setup_scheduled = nil
        if not plugin.setup_closed then Setup.show(plugin) end
    end
    UIManager:nextTick(plugin.setup_scheduled)
end

function Setup.close(plugin)
    plugin.setup_closed = true
    plugin.setup_proofs = nil
    if plugin.setup_scheduled then UIManager:unschedule(plugin.setup_scheduled); plugin.setup_scheduled = nil end
    if plugin.setup_job then plugin.setup_job:cancel(true) end
    if plugin.setup_dialog then UIManager:close(plugin.setup_dialog); plugin.setup_dialog = nil end
    if plugin.setup_chooser then
        if plugin.setup_chooser.button_dialog then UIManager:close(plugin.setup_chooser.button_dialog) end
        UIManager:close(plugin.setup_chooser); plugin.setup_chooser = nil
    end
end

return Setup
