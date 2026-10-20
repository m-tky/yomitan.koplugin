local Automatic = require("yomitan/automatic")
local ButtonDialog = require("ui/widget/buttondialog")
local Catalog = require("yomitan/catalog")
local DataStorage = require("datastorage")
local Search = require("yomitan/search")
local Setup = require("yomitan/setup")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")

local Yomitan = WidgetContainer:extend{
    name = "yomitan",
    display_name = "Yomitan",
    provider_id = "yomitan", -- ReaderUI rewrites module.name after initialization.
    is_doc_only = false,
}

function Yomitan:init()
    self.setup_closed = false
    self.root = DataStorage:getDataDir() .. "/data/yomitan"
    Catalog.enablePersistentVerification(self.root)
    self.compatible = self.ui and self.ui.dictionary and self.ui.dictionary.registerLookupProvider ~= nil
    if self.compatible then self.ui.dictionary:registerLookupProvider(self.provider_id, self) end
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

-- Search assistance only: definition popups always belong to StarDict.
function Yomitan:lookup()
    return {status = "declined"}
end

function Yomitan:getLookupCandidates(word)
    if not util.hasCJKChar(word) then return nil end
    local result = Search.find(word, self:getDatabases())
    local candidates, seen = {}, {[word] = true}
    for _, hit in ipairs(result.entries) do
        if hit.state.length == result.originalTextLength then
            for _, key in ipairs({hit.entry.term, hit.entry.reading}) do
                if key ~= "" and not seen[key] then
                    candidates[#candidates + 1], seen[key] = key, true
                end
            end
        end
    end
    return candidates
end

function Yomitan:improveSelection(args)
    if args.text ~= "" and not util.hasCJKChar(args.text) then return {status = "declined"} end
    return {status = "handled", range = Search.select(args, self:getDatabases())}
end

function Yomitan:onReaderReady()
    if self.compatible then
        Setup.recover(self)
        Automatic.start(self)
        Setup.auto(self)
    end
end

function Yomitan:onCloseDocument()
    Setup.close(self)
    if self.compatible then self.ui.dictionary:unregisterLookupProvider(self.provider_id) end
    self:closeDatabases()
end

-- FileManager has no CloseDocument event; release its provider/workers too.
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
        title = _("Yomitan") .. "\n" .. _("The search index is selected and verified automatically. Definitions come from StarDict."),
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
        help_text = _("Recognize Japanese words with Yomitan; show definitions from StarDict. Long-press for index import and source information."),
        hold_callback = function() self:showDetails() end,
        hold_keep_menu_open = false,
        sub_item_table = {
            {
                text = _("Enabled"), enabled = not not self.compatible,
                checked_func = function() return G_reader_settings:readSetting("dictionary_provider") == self.provider_id end,
                callback = function()
                    if G_reader_settings:readSetting("dictionary_provider") == self.provider_id then
                        G_reader_settings:delSetting("dictionary_provider")
                        if self.automatic_verifying and self.setup_job then self.setup_job:cancel(true) end
                    else
                        G_reader_settings:saveSetting("dictionary_provider", self.provider_id)
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
