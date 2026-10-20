local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Job = require("yomitan/importjob")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Updater = {}

local function message(plugin, text)
    if not plugin.setup_closed then UIManager:show(InfoMessage:new{text = text}) end
end

local function launch(plugin, mode, payload, done)
    if plugin.setup_closed then return end
    if plugin.setup_job then message(plugin, _("A Yomitan background task is already running. Please wait.")); return end
    local Update = require("yomitan/update")
    assert(lfs.symlinkattributes(plugin.path, "mode") == "directory", "Self-update requires a normal plugin directory, not a symlink")
    local target = assert(ffiUtil.realpath(plugin.path))
    assert(target:match("/yomitan%.koplugin$"), "Unsupported plugin directory name")
    local parent = target:match("^(.*)/[^/]+$")
    Job.recover(parent, ".yomitan-update-", Update.cleanup)
    local ok, job = pcall(Job.start, parent, plugin.path, "", mode, payload, {
        worker_script = "update-worker.lua", stage_prefix = ".yomitan-update-", cleanup = Update.cleanup,
        title = _("Updating Yomitan…"),
        cancel_title = _("Cancelling update…\nThe installed plugin and search indexes will be kept."),
        done = function(result, stage)
            plugin.setup_job = nil
            if not plugin.setup_closed then done(result, stage, target) end
        end,
        error = function(err) plugin.setup_job = nil; message(plugin, _("Yomitan update failed. Settings and search indexes were not changed.") .. "\n\n" .. err) end,
        cancelled = function() plugin.setup_job = nil end,
    })
    if ok then plugin.setup_job = job else message(plugin, tostring(job)) end
end

function Updater.install(plugin, release)
    local ok, providers = pcall(require, "apps/reader/modules/dictionaryprovider")
    if not ok or type(providers.candidates) ~= "function" then
        message(plugin, _("This release requires this fork's search-candidate hooks. Update KOReader separately first."))
        return
    end
    local success, err = pcall(launch, plugin, "install-update", {release = release}, function(result, stage, target)
        assert(result.kind == "install" and result.version == release.version, "Unexpected updater response")
        plugin:closeDatabases()
        local backup = require("yomitan/update").publish(stage, target)
        plugin.update_installed = true
        message(plugin, _("Yomitan was updated. Restart KOReader to load it. Settings and search indexes were retained.") ..
            "\n\n" .. _("Previous plugin backup:") .. "\n" .. backup)
    end)
    if not success then message(plugin, tostring(err)) end
end

function Updater.check(plugin)
    if plugin.update_installed then message(plugin, _("Restart KOReader before checking for another plugin update.")); return end
    local ok, err = pcall(function()
        local current = assert(dofile(plugin.path .. "/_meta.lua").version)
        launch(plugin, "check-update", {current = current}, function(result)
            assert(result.kind == "check", "Unexpected updater response")
            if result.unpublished then
                message(plugin, _("No public Yomitan release is available yet. The update source is prepared but has not been published."))
            elseif not result.available then
                message(plugin, _("Yomitan is up to date."))
            else
                local dialog
                dialog = ConfirmBox:new{
                    text = "Yomitan " .. current .. " → " .. result.release.version .. "\n\n" ..
                        _("Download and install this plugin update? Settings and search indexes are retained. A KOReader restart will be required."),
                    ok_text = _("Update"),
                    ok_callback = function() plugin.setup_dialog = nil; Updater.install(plugin, result.release) end,
                    cancel_callback = function() plugin.setup_dialog = nil end,
                }
                plugin.setup_dialog = dialog
                UIManager:show(dialog)
            end
        end)
    end)
    if not ok then message(plugin, tostring(err)) end
end

return Updater
