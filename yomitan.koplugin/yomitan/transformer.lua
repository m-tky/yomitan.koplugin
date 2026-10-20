-- Lua port of Yomitan's LanguageTransformer.transform (GPL-3.0-or-later).
-- Copyright (C) 2024-2026 Yomitan Authors
-- See ../README.md for the pinned sources and regeneration procedure.
local bit = require("bit")
local JSON = require("rapidjson")

local Yomitan = {}
local data, buckets
local MAX_STATES = 4096

local function load()
    if data then return end
    local directory = debug.getinfo(1, "S").source:match("^@(.*/)")
    local file = assert(io.open(directory .. "yomitan-transforms.json", "rb"))
    local content = file:read("*a")
    file:close()
    data = JSON.decode(content)
    buckets = {}
    for _, transform in ipairs(data.transforms) do
        for index, rule in ipairs(transform.rules) do
            rule.transform, rule.ruleIndex = transform.id, index - 1
            local key = rule.input:sub(-3)
            buckets[key] = buckets[key] or {}
            table.insert(buckets[key], rule)
        end
    end
end

function Yomitan.conditionsMatch(current, next_conditions)
    return current == 0 or bit.band(current, next_conditions) ~= 0
end

function Yomitan.conditionType(name)
    load()
    return data.conditionTypes[name] or 0
end

function Yomitan.dictionaryConditions(parts_of_speech)
    load()
    local flags = 0
    for _, part in ipairs(parts_of_speech or {}) do
        flags = bit.bor(flags, data.dictionaryConditions[part] or 0)
    end
    return flags
end

-- Preserve BFS order, condition flags, every derivation, and cycle detection by
-- (transform, rule index, input text) in the current trace, as in the JS engine.
-- In particular, do NOT deduplicate by term: identical text with different
-- conditions or derivations can have different valid dictionary matches.
function Yomitan.transform(text)
    load()
    local results = {{term = text, conditions = 0, rules = 0, trace = {}, reasons = {}}}
    local index = 1
    while index <= #results do
        local current = results[index]
        for _, rule in ipairs(buckets[current.term:sub(-3)] or {}) do
            if Yomitan.conditionsMatch(current.conditions, rule.conditionsIn)
                    and #current.term >= #rule.input and current.term:sub(-#rule.input) == rule.input
                    and (rule.type ~= "wholeWord" or current.term == rule.input) then
                local cycle = false
                for _, frame in ipairs(current.trace) do
                    if frame.transform == rule.transform and frame.ruleIndex == rule.ruleIndex
                            and frame.text == current.term then
                        cycle = true
                        break
                    end
                end
                if not cycle then
                    -- Fail closed rather than returning a different partial candidate set.
                    if #results >= MAX_STATES then return nil, "Yomitan transformation state limit exceeded" end
                    local trace = {{transform = rule.transform, ruleIndex = rule.ruleIndex, text = current.term}}
                    local reasons = {rule.transform}
                    for i, frame in ipairs(current.trace) do
                        trace[i + 1] = frame
                        reasons[i + 1] = frame.transform
                    end
                    local term = rule.type == "wholeWord" and rule.output
                        or current.term:sub(1, #current.term - #rule.input) .. rule.output
                    results[#results + 1] = {
                        term = term, conditions = rule.conditionsOut, rules = rule.conditionsOut,
                        trace = trace, reasons = reasons,
                    }
                end
            end
        end
        index = index + 1
    end
    return results
end

return Yomitan
