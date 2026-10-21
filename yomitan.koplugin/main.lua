local Automatic = require("yomitan/automatic")
local ButtonDialog = require("ui/widget/buttondialog")
local Catalog = require("yomitan/catalog")
local DataStorage = require("datastorage")
local LanguageSupport = require("languagesupport")
local Search = require("yomitan/search")
local Setup = require("yomitan/setup")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")

local Yomitan = WidgetContainer:extend{
    name = "yomitan",
    display_name = "Yomitan",
    pretty_name = "Yomitan",
    is_doc_only = false,
}

function Yomitan:init()
    self.setup_closed = false
    self.root = DataStorage:getDataDir() .. "/data/yomitan"
    Catalog.enablePersistentVerification(self.root)
    self.compatible = type(LanguageSupport.registerPlugin) == "function"
    -- Migrate the old fork-only setting without changing another provider.
    if G_reader_settings:readSetting("yomitan_enabled") == nil then
        G_reader_settings:saveSetting("yomitan_enabled",
            G_reader_settings:readSetting("dictionary_provider") == "yomitan")
    end
    if G_reader_settings:readSetting("dictionary_provider") == "yomitan" then
        G_reader_settings:delSetting("dictionary_provider")
    end
    -- ReaderUI rewrites module.name; register a stable adapter instead of self.
    local plugin = self
    self.language_plugin = {
        name = "yomitan", pretty_name = "Yomitan",
        supportsLanguage = function(_, code) return code == "ja" or code == "jpn" end,
        onWordLookup = function(_, args) return plugin:onWordLookup(args) end,
        onWordSelection = function(_, args) return plugin:onWordSelection(args) end,
    }
    self:updateLanguageRegistration()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.compatible and not self.ui.document and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            self.setup_scheduled = function()
                self.setup_scheduled = nil
                if not self.setup_closed then Setup.recover(self); Automatic.start(self) end
            end
            UIManager:nextTick(self.setup_scheduled)
        end)
    end
end

function Yomitan:isEnabled()
    return not self.setup_closed and G_reader_settings:isTrue("yomitan_enabled")
end

function Yomitan:updateLanguageRegistration()
    if self.compatible and self:isEnabled() then
        LanguageSupport:registerPlugin(self.language_plugin)
    elseif LanguageSupport.plugins.yomitan == self.language_plugin then
        -- The registry is shared by FileManager and ReaderUI. Do not remove a
        -- newer instance's registration when the previous UI closes.
        LanguageSupport.plugins.yomitan = nil
    end
end

function Yomitan:setEnabled(enabled)
    G_reader_settings:saveSetting("yomitan_enabled", enabled)
    self:updateLanguageRegistration()
    if enabled then self:warnLanguageConflict() end
end

function Yomitan:warnLanguageConflict()
    if self:isEnabled() and LanguageSupport.plugins.japanese then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Disable the Japanese plugin in Plugin Management and restart KOReader to use Yomitan. Language plugins have no defined priority."),
        })
    end
end

function Yomitan:selectedIds(catalog)
    return Automatic.select(catalog, G_reader_settings:readSetting("yomitan_dictionary_ids"))
end

function Yomitan:getDatabases()
    if self.automatic_verifying or self.automatic_failed then return {} end
    if self.databases then return self.databases end
    local catalog = Catalog.scan(self.root)
    local ids, by_id = self:selectedIds(catalog), {}
    for _, item in ipairs(catalog) do by_id[item.id] = item end
    local opened = {}
    local ok, err = pcall(function()
        for _, id in ipairs(ids) do
            assert(by_id[id], "The selected Yomitan search index is missing")
            opened[#opened + 1] = Catalog.open(by_id[id])
        end
    end)
    if not ok then
        for _, db in ipairs(opened) do db:close() end
        error(err)
    end
    self.databases = opened
    return opened
end

function Yomitan:closeDatabases()
    for _, db in ipairs(self.databases or {}) do db:close() end
    self.databases = nil
end

function Yomitan:getLookupCandidates(word)
    if not util.hasCJKChar(word) then return nil end
    local result = Search.find(word, self:getDatabases())
    local candidates, seen, bytes = {}, {[word] = true}, 0
    for _, hit in ipairs(result.entries) do
        if hit.state.length == result.originalTextLength then
            for _, key in ipairs({hit.entry.term, hit.entry.reading}) do
                if key ~= "" and not seen[key] then
                    bytes = bytes + #key
                    if #candidates >= 512 or bytes > 65536 then return nil end
                    candidates[#candidates + 1], seen[key] = key, true
                end
            end
        end
    end
    return candidates
end

-- LanguageSupport owns selection updates and StarDict definition popups.
function Yomitan:onWordLookup(args)
    if not self:isEnabled() or self.setup_job then return end
    return self:getLookupCandidates(args.text)
end

function Yomitan:onWordSelection(args)
    if not self:isEnabled() or self.setup_job then return end
    if args.text ~= "" and not util.hasCJKChar(args.text) then return end
    return Search.select(args, self:getDatabases())
end

function Yomitan:onReaderReady()
    self:warnLanguageConflict()
    if self.compatible then
        Setup.recover(self)
        Automatic.start(self)
        Setup.auto(self)
    end
end

function Yomitan:onCloseDocument()
    Setup.close(self)
    self:updateLanguageRegistration()
    self:closeDatabases()
end

-- FileManager has no CloseDocument event; release its registration/workers too.
function Yomitan:onCloseWidget()
    self:onCloseDocument()
end

function Yomitan:showSearchSources()
    local parts = {require("yomitan/jmdict").notice, "Index location: " .. self.root}
    local function append(path)
        local file = io.open(path, "rb")
        if file then
            parts[#parts + 1] = util.fixUtf8(file:read(65536) or "", "?")
            file:close()
        end
    end
    for _, item in ipairs(Catalog.scan(self.root)) do
        if not item.error then
            parts[#parts + 1] = item.title .. "\nLocal licence and documentation: " .. item.path
            append(item.path .. "/SOURCES.txt")
        end
    end
    -- Retain visibility of notices supplied with legacy manually installed indexes.
    append(self.root .. "/SOURCES.txt")
    append(self.root .. "/JMdict-SOURCES.txt")
    UIManager:show(require("ui/widget/textviewer"):new{title = _("Search index sources"), text = table.concat(parts, "\n\n")})
end

function Yomitan:showDetails()
    local dialog
    local function close() UIManager:close(dialog); self.setup_dialog = nil end
    dialog = ButtonDialog:new{
        dismissable = false,
        title = _("Yomitan"),
        buttons = {
            {{text = _("Add search index"), callback = function() close(); Setup.show(self) end}},
            {{text = _("Sources and licences"), callback = function() close(); self:showSearchSources() end}},
            {{text = _("Close"), callback = close}},
        },
    }
    self.setup_dialog = dialog
    UIManager:show(dialog)
end

function Yomitan:addToMainMenu(menu_items)
    menu_items.yomitan_settings = {
        text = _("Yomitan"), sorting_hint = "more_tools",
        help_text = _("Japanese word selection. Long-press for setup and sources."),
        hold_callback = function() self:showDetails() end,
        hold_keep_menu_open = false,
        sub_item_table = {
            {
                text = _("Enabled"), enabled = not not self.compatible,
                checked_func = function() return self:isEnabled() end,
                callback = function()
                    if self:isEnabled() then
                        self:setEnabled(false)
                        if self.automatic_verifying and self.setup_job then self.setup_job:cancel(true) end
                    else
                        self:setEnabled(true)
                        self.automatic_failed = nil
                        Automatic.start(self)
                        if #self:selectedIds(Catalog.scan(self.root)) == 0 then Setup.show(self) end
                    end
                    self:closeDatabases()
                end,
            },
            {text = _("Check for updates"), callback = function() require("yomitan/update_ui").check(self) end},
        },
    }
end

return Yomitan
