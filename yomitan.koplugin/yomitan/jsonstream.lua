-- Bounded strict JSON reader. A bank is consumed one top-level array item at a
-- time; neither the compressed entry nor the whole decoded bank is retained.
local JSON = require("rapidjson")
local util = require("util")
local Parser = {}

function Parser.new(read, max_value)
    return setmetatable({read = read, buffer = "", pos = 1, bytes = 0,
        max_value = max_value or 2 * 1024 * 1024}, {__index = Parser})
end

function Parser:peek()
    if self.pos > #self.buffer then
        self.buffer = self.read() or ""
        self.pos = 1
    end
    return self.buffer:sub(self.pos, self.pos)
end

function Parser:advance(count)
    self.pos, self.bytes = self.pos + count, self.bytes + count
    assert(not self.start or self.bytes - self.start <= self.max_value, "JSON value exceeds the device limit")
end

function Parser:space()
    while self:peek():match("[ \r\n\t]") do self:advance(1) end
end

function Parser:take(char)
    assert(self:peek() == char, "Invalid JSON: expected " .. char)
    self:advance(1)
end

function Parser:string()
    self:take('"')
    local parts = {'"'}
    while true do
        assert(self:peek() ~= "", "Unterminated JSON string")
        local first = self.pos
        local special = self.buffer:find('["\\%z\1-\31]', first)
        local last = special and special - 1 or #self.buffer
        if last >= first then
            parts[#parts + 1] = self.buffer:sub(first, last)
            self:advance(last - first + 1)
        end
        if special then
            local char = self:peek()
            assert(char == '"' or char == "\\", "Control character in JSON string")
            parts[#parts + 1] = char
            self:advance(1)
            if char == '"' then break end
            local escaped = self:peek()
            assert(escaped ~= "", "Truncated JSON escape")
            parts[#parts + 1] = escaped
            self:advance(1)
        end
    end
    local value, err = JSON.decode(table.concat(parts))
    assert(type(value) == "string", err or "Invalid JSON string")
    assert(not value:find("%z") and util.fixUtf8(value, "?") == value, "Invalid Unicode or NUL in JSON")
    return value
end

function Parser:value(depth)
    depth = depth or 0
    self.nodes = (self.nodes or 0) + 1
    assert(depth <= 64 and self.nodes <= 16384, "JSON nesting/node limit exceeded")
    self:space()
    local char = self:peek()
    if char == '"' then return self:string() end
    if char == "[" or char == "{" then
        local array = char == "["
        self:advance(1)
        local result = array and JSON.array() or JSON.object()
        local finish = array and "]" or "}"
        self:space()
        if self:peek() == finish then self:advance(1); return result end
        while true do
            self:space()
            local key
            if not array then
                assert(self:peek() == '"', "JSON object key must be a string")
                key = self:string()
                assert(result[key] == nil, "Duplicate JSON object property")
                self:space()
                self:take(":")
            end
            local value = self:value(depth + 1)
            if array then result[#result + 1] = value else result[key] = value end
            self:space()
            if self:peek() == finish then self:advance(1); return result end
            self:take(",")
        end
    end
    local parts = {}
    while self:peek() ~= "" and not self:peek():match("[ \r\n\t,%]%}]") do
        parts[#parts + 1] = self:peek()
        self:advance(1)
        assert(#parts <= 128, "Oversized JSON scalar")
    end
    local literal = table.concat(parts)
    if literal == "null" then return JSON.null end
    if literal == "true" then return true end
    if literal == "false" then return false end
    -- RapidJSON validates the exact number grammar (no NaN, trailing garbage,
    -- leading zero, or Infinity), rather than accepting Lua's tonumber syntax.
    assert(literal:match("^%-?%d"), "Invalid JSON value")
    local mantissa, exponent = literal:match("^(.-)[eE](.*)$")
    if exponent then assert(exponent:match("^[+-]?%d+$"), "Invalid JSON exponent") else mantissa = literal end
    mantissa = mantissa:gsub("^%-", "")
    local integer, fraction = mantissa:match("^(%d+)%.(%d+)$")
    if not fraction then integer = mantissa:match("^%d+$") end
    assert(integer and (#integer == 1 or integer:sub(1, 1) ~= "0"), "Invalid JSON number grammar")
    local number = JSON.decode(literal)
    assert(type(number) == "number" and number == number and math.abs(number) < math.huge, "Invalid JSON number")
    return number
end

function Parser:bom()
    if self.bytes == 0 and self:peek() == "\239" then
        self:advance(1); self:take("\187"); self:take("\191")
    end
end

function Parser:one()
    self:bom()
    self.start, self.nodes = self.bytes, 0
    local value = self:value()
    self:space()
    assert(self:peek() == "", "Trailing data after JSON value")
    self.start = nil
    return value
end

function Parser:each(callback)
    self:bom()
    self:space()
    self:take("[")
    self:space()
    if self:peek() ~= "]" then
        local row = 0
        while true do
            self.start, self.nodes = self.bytes, 0
            local value = self:value()
            self.start = nil
            callback(value, row)
            row = row + 1
            self:space()
            if self:peek() == "]" then break end
            self:take(",")
        end
    end
    self:take("]")
    self:space()
    assert(self:peek() == "", "Trailing data after JSON bank")
end

return Parser
