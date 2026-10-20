-- UI-side worker supervisor. Heavy parsing/SQLite/checks run in a fresh bundled
-- LuaJIT process, not the inherited reader VM. Only the parent may publish.
local ButtonDialog = require("ui/widget/buttondialog")
local JSON = require("rapidjson")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
require("ffi/posix_h")
local Job = {}
local controls = {['owner.json']=true, ['owner.json.tmp']=true, ['progress.json']=true,
    ['progress.json.tmp']=true, ['result.json']=true, ['result.json.tmp']=true,
    ['jmdict-release.json']=true, ['download.zip']=true, ['jmdict.zip']=true, ['JMdict-SOURCES.txt']=true,
    ['JMdict-LICENSE.txt']=true, ['JMdict-documentation.html']=true}
local bundle_files = {['dictionary.sqlite3']=true, ['dictionary.sqlite3-journal']=true,
    ['dictionary.sqlite3-wal']=true, ['dictionary.sqlite3-shm']=true, ['manifest.json']=true,
    ['package.json']=true, ['SOURCES.txt']=true, ['JMdict-LICENSE.txt']=true,
    ['JMdict-documentation.html']=true, ['JMdict-index.json']=true, ['README.txt']=true}

function Job.read(path)
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read(65537)
    file:close()
    if not data or #data > 65536 then return end
    local ok, value = pcall(JSON.decode, data)
    if ok and type(value) == "table" then return value end
end

function Job.write(path, value)
    local file = assert(io.open(path .. ".tmp", "wb"))
    assert(file:write(assert(JSON.encode(value))))
    assert(file:close())
    assert(os.rename(path .. ".tmp", path))
end

local function removeFiles(path, allowed)
    if not lfs.symlinkattributes(path) then return true end
    if lfs.symlinkattributes(path, "mode") ~= "directory" then return false end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not allowed[name] or lfs.symlinkattributes(path .. "/" .. name, "mode") == "directory" then return false end
        end
    end
    for name in pairs(allowed) do os.remove(path .. "/" .. name) end
    return lfs.rmdir(path) ~= nil
end

function Job.cleanup(stage)
    if not lfs.symlinkattributes(stage) then return true end
    if lfs.symlinkattributes(stage, "mode") ~= "directory" then return false end
    if not removeFiles(stage .. "/bundle", bundle_files) then return false end
    return removeFiles(stage, controls) -- Owner marker is kept until bundle cleanup finishes.
end

local function alive(pid)
    return type(pid) == "number" and pid > 0 and pid < 2147483648 and pid % 1 == 0 and ffi.C.kill(pid, 0) == 0
end

function Job.recover(root, prefix, cleanup)
    prefix, cleanup = prefix or ".import-setup-", cleanup or Job.cleanup
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for name in lfs.dir(root) do
        if name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^%w+$") then
            local stage = root .. "/" .. name
            if lfs.symlinkattributes(stage, "mode") == "directory" then
                local owner = Job.read(stage .. "/owner.json")
                if owner and not alive(owner.parent_pid) and not alive(owner.child_pid) then
                    cleanup(stage)
                end
            end
        end
    end
end

function Job.start(root, plugin_root, source, mode, ids, callbacks)
    util.makePath(root)
    assert(lfs.attributes(root, "mode") == "directory", "Unable to create dictionary storage")
    local _, _, available = ffiUtil.df(root)
    assert(type(available) == "number" and available >= 24 * 1024^2, "Not enough free space for device import")
    callbacks = callbacks or {}
    local prefix = callbacks.stage_prefix or ".import-setup-"
    assert(prefix:match("^%.[%w%-]+%-$"), "Invalid staging prefix")
    local template = ffi.new("char[?]", #root + #prefix + 16, root .. "/" .. prefix .. "XXXXXX")
    local pointer = ffi.C.mkdtemp(template)
    assert(pointer ~= nil, "Unable to create private import staging directory")
    local self = setmetatable({stage = ffi.string(pointer), callbacks = callbacks or {}}, {__index = Job})
    local parent_pid = tonumber(ffi.C.getpid())
    Job.write(self.stage .. "/owner.json", {parent_pid = parent_pid})
    local args = {"./luajit", plugin_root .. "/" .. (callbacks.worker_script or "import.lua"),
        source or "", self.stage, root, plugin_root, mode, assert(JSON.encode(ids))}
    local argv = ffi.new("char *[?]", #args + 1)
    self.buffers = {}
    for i, argument in ipairs(args) do
        self.buffers[i] = ffi.new("char[?]", #argument + 1, argument)
        argv[i - 1] = self.buffers[i]
    end
    local pid, err = ffiUtil.runInSubProcess(function(child_pid)
        collectgarbage("stop") -- Do not finalize inherited reader/database objects before exec.
        Job.write(self.stage .. "/owner.json", {parent_pid = parent_pid, child_pid = child_pid})
        ffi.C.execvp(argv[0], argv)
        Job.write(self.stage .. "/result.json", {status = "error", message = "Unable to start bundled LuaJIT for index installation"})
    end)
    if not pid then (callbacks.cleanup or Job.cleanup)(self.stage); error(err) end
    self.pid = pid
    if not self.callbacks.background then
        self.dialog = ButtonDialog:new{
            title = (callbacks.title or "Setting up Yomitan dictionaries…") .. "\nPreparation in progress.", dismissable = false,
            buttons = {{{text = "Cancel", callback = function() self:cancel() end}}},
        }
    end
    UIManager:preventStandby()
    if self.dialog then UIManager:show(self.dialog) end
    self.poll = function() self:step() end
    UIManager:scheduleIn(0.15, self.poll)
    return self
end

function Job:cancel(silent)
    if self.finished then return end
    self.cancelled = true
    if ffiUtil.isSubProcessDone(self.pid) then
        self.reaped = true
    else
        -- The unreaped child PID cannot be reused here. Also kill the PID
        -- itself in case cancellation precedes the child's setpgid().
        ffi.C.kill(-self.pid, 9)
        ffi.C.kill(self.pid, 9)
    end
    if self.dialog then
        if silent then UIManager:close(self.dialog); self.dialog = nil
        else self.dialog:setTitle(self.callbacks.cancel_title or "Cancelling import…\nExisting dictionaries and settings will be kept.") end
    end
end

function Job:step()
    if self.finished then return end
    if not self.reaped and not ffiUtil.isSubProcessDone(self.pid) then
        if self.dialog and not self.cancelled then
            local progress = Job.read(self.stage .. "/progress.json")
            if progress and type(progress.phase) == "string" then
                local title = (self.callbacks.title or "Setting up Yomitan dictionaries…") .. "\n" .. progress.phase .. ": " .. tostring(progress.amount or "")
                if title ~= self.last_title then self.dialog:setTitle(title); self.last_title = title end
            end
        end
        UIManager:scheduleIn(0.15, self.poll)
        return
    end
    -- Reap before deleting anything: a SIGKILL'ed worker cannot recreate files
    -- under the directory while its parent cleans them up.
    self.finished = true
    UIManager:unschedule(self.poll)
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    UIManager:allowStandby()
    local result = Job.read(self.stage .. "/result.json")
    local ok, message = true
    if self.cancelled then
        if self.callbacks.cancelled then self.callbacks.cancelled() end
    elseif result and (result.status == "prepared" or result.status == "existing" or result.status == "verified") then
        if self.callbacks.done then ok, message = pcall(self.callbacks.done, result, self.stage) end
    else
        ok, message = false, result and result.message or "Import worker exited without a valid result (memory/IO failure)"
    end
    local cleaned = (self.callbacks.cleanup or Job.cleanup)(self.stage)
    if not cleaned then ok, message = false, "Import staging could not be cleaned; unknown files were left untouched: " .. self.stage end
    if not ok and self.callbacks.error then self.callbacks.error(tostring(message)) end
    self.buffers = nil
end

return Job
