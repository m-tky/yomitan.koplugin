-- ZIP-only streaming input. Preflight the bounded central directory ourselves
-- so names, encryption, symlinks, duplicate members and declared expansion can
-- be rejected before libarchive decodes any bank. No archive path is extracted.
local ffi = require("ffi")
local bit = require("bit")
require("ffi/libarchive_h")
ffi.cdef[[
int archive_read_support_format_zip_seekable(struct archive *);
int archive_entry_is_encrypted(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
]]
local archive = ffi.loadlib("archive", "13")
local Zip = {}

local function u16(text, pos)
    local a, b = text:byte(pos, pos + 1)
    assert(b, "Truncated ZIP metadata")
    return a + b * 256
end
local function u32(text, pos)
    return u16(text, pos) + u16(text, pos + 2) * 65536
end

local function safeName(name)
    assert(name ~= "" and not name:find("[%z\1-\31\\:]") and name:sub(1, 1) ~= "/", "Unsafe ZIP member name")
    local path = name:gsub("/$", "")
    assert(path ~= "" and not path:find("//", 1, true), "Unsafe ZIP member path")
    for part in path:gmatch("[^/]+") do assert(part ~= "." and part ~= "..", "ZIP path traversal") end
end

function Zip.open(path, progress)
    local file = assert(io.open(path, "rb"))
    local ok, members = pcall(function()
        local size = assert(file:seek("end"))
        assert(size <= 2 * 1024^3 and size >= 22, "Unsupported ZIP size")
        file:seek("set", math.max(0, size - 65557))
        local tail, eocd = file:read("*a")
        for i = #tail - 21, 1, -1 do
            if tail:sub(i, i + 3) == "PK\5\6" and i + 21 + u16(tail, i + 20) == #tail then eocd = i; break end
        end
        assert(eocd, "Missing ZIP end record")
        local count = u16(tail, eocd + 10)
        assert(u16(tail, eocd + 4) == 0 and u16(tail, eocd + 6) == 0
            and u16(tail, eocd + 8) == count, "Multi-volume ZIP is unsupported")
        assert(count < 65535 and count <= 5000, "ZIP64 or more than 5000 ZIP members: use the PC converter")
        local length, offset = u32(tail, eocd + 12), u32(tail, eocd + 16)
        assert(length <= 4 * 1024^2 and offset + length == size - #tail + eocd - 1,
            "Unsupported ZIP directory layout (ZIP64/SFX/trailing data)")
        file:seek("set", offset)
        local directory = assert(file:read(length))
        assert(#directory == length, "Truncated ZIP central directory")
        local result, aliases, pos, total = {}, {}, 1, 0
        for index = 1, count do
            assert(directory:sub(pos, pos + 3) == "PK\1\2", "Invalid ZIP central record")
            local flags, method = u16(directory, pos + 8), u16(directory, pos + 10)
            local compressed, expanded = u32(directory, pos + 20), u32(directory, pos + 24)
            local name_len, extra_len, comment_len = u16(directory, pos + 28), u16(directory, pos + 30), u16(directory, pos + 32)
            assert(pos + 45 + name_len + extra_len + comment_len <= #directory, "Truncated ZIP member record")
            local name = directory:sub(pos + 46, pos + 45 + name_len)
            safeName(name)
            local alias = name:gsub("/$", ""):lower()
            assert(not aliases[alias], "Duplicate or case-ambiguous ZIP member")
            aliases[alias] = true
            local mode = bit.band(math.floor(u32(directory, pos + 38) / 65536), 61440)
            assert(mode == 0 or mode == 32768 or mode == 16384, "ZIP links/special files are unsupported")
            assert(bit.band(flags, 1) == 0 and bit.band(flags, 64) == 0, "Encrypted ZIP is unsupported")
            assert(method == 0 or method == 8, "Device import supports stored/deflate ZIP only")
            assert(u16(directory, pos + 34) == 0 and u32(directory, pos + 42) < offset, "Invalid ZIP member location")
            total = total + expanded
            assert(total <= 2 * 1024^3 and (expanded <= 1024^2 or expanded <= math.max(compressed, 1) * 2000), "ZIP expansion limit exceeded")
            if name:sub(-1) ~= "/" then
                assert(mode ~= 16384, "Ambiguous ZIP directory entry")
                result[name] = {name = name, size = expanded, index = index}
            end
            pos = pos + 46 + name_len + extra_len + comment_len
            if progress and index % 100 == 0 then progress("Checking ZIP members", index) end
        end
        assert(pos == #directory + 1, "Unexpected ZIP directory data")
        return result
    end)
    file:close()
    assert(ok, members)
    return setmetatable({path = path, members = members, buffer = ffi.new("uint8_t[32768]")}, {__index = Zip})
end

function Zip:close()
    if self.handle then
        archive.archive_read_close(self.handle)
        archive.archive_free(ffi.gc(self.handle, nil))
        self.handle = nil
    end
end

function Zip:rewind()
    self:close()
    self.handle = ffi.gc(archive.archive_read_new(), archive.archive_free)
    assert(self.handle ~= nil, "Unable to allocate ZIP reader")
    assert(archive.archive_read_support_format_zip_seekable(self.handle) == 0, "ZIP decoder unavailable")
    assert(archive.archive_read_open_filename(self.handle, self.path, 32768) == 0, "Unable to open ZIP")
    self.entry = self.entry or ffi.gc(archive.archive_entry_new(), archive.archive_entry_free)
    self.current = nil
end

function Zip:stream(member, max_bytes, progress)
    assert(member and member.size <= max_bytes, "Missing or oversized ZIP bank")
    self:rewind()
    while true do
        local code = archive.archive_read_next_header2(self.handle, self.entry)
        assert(code == 0, "Unable to find/decode ZIP member")
        local name = archive.archive_entry_pathname(self.entry)
        assert(name ~= nil, "Invalid ZIP member pathname")
        if ffi.string(name) == member.name then break end
    end
    assert(archive.archive_entry_is_encrypted(self.entry) == 0 and archive.archive_entry_hardlink(self.entry) == nil
        and archive.archive_entry_filetype(self.entry) == 32768, "Unsafe ZIP bank type")
    assert(tonumber(archive.archive_entry_size(self.entry)) == member.size, "ZIP bank size mismatch")
    local received = 0
    return function()
        local count = tonumber(archive.archive_read_data(self.handle, self.buffer, 32768))
        assert(count >= 0, "ZIP data/CRC validation failed")
        received = received + count
        assert(received <= max_bytes and received <= member.size, "ZIP bank expansion exceeds its limit")
        if progress then progress("Reading " .. member.name, received) end
        if count == 0 then assert(received == member.size, "Truncated ZIP bank"); return nil end
        return ffi.string(self.buffer, count)
    end
end

return Zip
