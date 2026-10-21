-- Portable contract tests: run from the repository root with LuaJIT.
-- Only KOReader/native dependencies are stubbed; plugin lifecycle, setup and
-- automatic verification use the shipped modules.
package.path = "yomitan.koplugin/?.lua;" .. package.path
local function stub(name, value)
    package.loaded[name] = value
end
local Widget = {}
function Widget:extend(value)
    return setmetatable(value or {}, {__index = self})
end
function Widget:new(value)
    local instance = self:extend(value)
    if instance.init then instance:init() end
    return instance
end
stub("ui/widget/container/widgetcontainer", Widget)
for _, name in ipairs({"buttondialog", "infomessage", "pathchooser"}) do
    stub("ui/widget/" .. name, Widget)
end
local settings = {}
G_reader_settings = {
    readSetting = function(_, key) return settings[key] end,
    saveSetting = function(_, key, value) settings[key] = value end,
    delSetting = function(_, key) settings[key] = nil end,
    isTrue = function(_, key) return settings[key] == true end,
}
local queued = {}
stub("ui/uimanager", {
    nextTick = function(_, callback) queued[#queued + 1] = callback end,
    unschedule = function() end,
    show = function() end,
    close = function() end,
})
stub("gettext", function(text) return text end)
stub("datastorage", {getDataDir = function() return "/test" end})
stub("logger", {warn = function() end, dbg = function() end, err = error})
stub("dbg", {dassert = assert})
stub("util", {hasCJKChar = function(text) return text:find("[\128-\255]") ~= nil end})
stub("libs/libkoreader-lfs", {})
local LanguageSupport
if arg[1] then
    -- Optional: exercise the real stock KOReader dispatch without native UI/FFI.
    LanguageSupport = dofile(arg[1] .. "/frontend/languagesupport.lua")
else
    LanguageSupport = {plugins = {}}
    function LanguageSupport:registerPlugin(plugin) self.plugins[plugin.name] = plugin end
end
stub("languagesupport", LanguageSupport)
local catalog, verified, opens, closes = {}, true, 0, 0
stub("yomitan/catalog", {
    enablePersistentVerification = function() end,
    scan = function() return catalog end,
    isVerified = function() return verified end,
    rememberVerified = function() end,
    open = function()
        opens = opens + 1
        return {close = function() closes = closes + 1 end}
    end,
})
local jobs = 0
stub("yomitan/importjob", {
    recover = function() end,
    start = function()
        jobs = jobs + 1
        return {cancel = function() end}
    end,
})
stub("yomitan/jmdict", {})
local candidates, selections = 0, 0
local search_result = {originalTextLength = 2, entries = {
    {state = {length = 2}, entry = {term = "食べる", reading = "たべる"}},
    {state = {length = 1}, entry = {term = "食", reading = "しょく"}},
    {state = {length = 2}, entry = {term = "食べる", reading = ""}},
}}
stub("yomitan/search", {
    find = function() candidates = candidates + 1; return search_result end,
    select = function(args)
        selections = selections + 1
        assert(args.callbacks == "callbacks")
        return {args.pos0, "new end"}
    end,
})
local Yomitan = dofile("yomitan.koplugin/main.lua")
local Automatic = require("yomitan/automatic")
local Setup = require("yomitan/setup")
local function new(ui) return Yomitan:new{ui = ui or {}, path = "yomitan.koplugin"} end
local function reset(values)
    settings = values or {}
    LanguageSupport.plugins = {}
    catalog, queued = {}, {}
end

-- No dictionary module/provider hooks are needed, including in FileManager.
reset()
local plugin = new()
assert(plugin.compatible and not plugin:isEnabled())
assert(not LanguageSupport.plugins.yomitan)
plugin:setEnabled(true)
local adapter = LanguageSupport.plugins.yomitan
assert(adapter.name == "yomitan" and adapter:supportsLanguage("ja"))
assert(adapter:supportsLanguage("jpn") and not adapter:supportsLanguage("en"))
plugin.name = "plugin_yomitan" -- ReaderUI changes the module's name.
assert(LanguageSupport.plugins.yomitan == adapter)
local result = adapter:onWordLookup{text = "食べた"}
assert(#result == 2 and result[1] == "食べる" and result[2] == "たべる")
local range = adapter:onWordSelection{
    text = "食", pos0 = "start", pos1 = "end", callbacks = "callbacks",
}
assert(#range == 2 and range[1] == "start" and range[2] == "new end")
assert(adapter:onWordLookup{text = "hello"} == nil)
assert(adapter:onWordSelection{text = "hello"} == nil)
assert(candidates == 1 and selections == 1)
if LanguageSupport._findAndCallPlugin then
    result = LanguageSupport:_findAndCallPlugin("ja", "WordLookup", {text = "食べた"})
    assert(#result == 2 and result[1] == "食べる")
    range = LanguageSupport:_findAndCallPlugin("ja", "WordSelection", {
        text = "食", pos0 = "start", callbacks = "callbacks",
    })
    assert(range[1] == "start" and range[2] == "new end")
end
plugin.setup_job = {}
assert(adapter:onWordLookup{text = "食"} == nil)
assert(adapter:onWordSelection{text = "食"} == nil)
plugin.setup_job = nil
plugin:setEnabled(false)
assert(not LanguageSupport.plugins.yomitan)
assert(adapter:onWordLookup{text = "食"} == nil)

-- Independent settings and one-time migration (including explicit disable).
reset{dictionary_provider = "yomitan"}
plugin = new()
assert(plugin:isEnabled() and settings.dictionary_provider == nil)
reset{dictionary_provider = "other"}
plugin = new()
assert(not plugin:isEnabled() and settings.dictionary_provider == "other")
plugin:setEnabled(true)
assert(settings.dictionary_provider == "other")
reset{dictionary_provider = "yomitan", yomitan_enabled = false}
assert(not new():isEnabled() and settings.dictionary_provider == nil)

-- No registration stealing/removal during a FileManager -> ReaderUI switch.
reset{yomitan_enabled = true}
local japanese = {}
LanguageSupport.plugins.japanese = japanese
local old = new()
plugin = new()
adapter = LanguageSupport.plugins.yomitan
old:onCloseWidget()
assert(LanguageSupport.plugins.yomitan == adapter)
assert(LanguageSupport.plugins.japanese == japanese)
catalog = {{id = "index", title = "JMdict [test]"}}
plugin:getDatabases()
plugin:onCloseDocument()
assert(not LanguageSupport.plugins.yomitan and opens == closes)
assert(adapter:onWordLookup{text = "食"} == nil)

-- Automatic verification is gated by the plugin setting, not the provider.
reset{yomitan_enabled = false, dictionary_provider = "other"}
plugin = new()
catalog = {{id = "index", title = "JMdict [test]"}}
verified = false
Automatic.start(plugin)
assert(jobs == 0)
plugin:setEnabled(true)
Automatic.start(plugin)
assert(jobs == 1 and plugin.automatic_verifying)
plugin:onCloseWidget()

-- Explicit setup activation registers language support and leaves providers alone.
reset{dictionary_provider = "other"}
plugin = new()
catalog = {{id = "index", title = "JMdict [test]"}}
plugin.setup_proofs = {index = {}}
Setup.complete(plugin, {"index"})
assert(plugin:isEnabled() and LanguageSupport.plugins.yomitan)
assert(settings.dictionary_provider == "other" and settings.yomitan_setup_version == 1)

-- Excess candidates fail closed, rather than handing StarDict a partial list.
search_result.entries = {}
for i = 1, 513 do
    search_result.entries[i] = {state = {length = 2}, entry = {term = "候補" .. i, reading = ""}}
end
assert(plugin:onWordLookup{text = "食"} == nil)
search_result.entries = {{state = {length = 2}, entry = {term = string.rep("字", 22000), reading = ""}}}
assert(plugin:onWordLookup{text = "食"} == nil)
plugin:onCloseWidget()
print("Language-support contract tests passed")
