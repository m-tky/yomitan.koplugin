-- Text-only first-release renderer. Dictionary markup is never executable HTML.
local util = require("util")
local Render = {}

function Render.definition(glossary)
    local parts, bytes, nodes, truncated = {}, 0, 0, false
    local function append(text)
        if type(text) ~= "string" then return end
        if bytes + #text > 32768 then
            for char in text:gmatch(util.UTF8_CHAR_PATTERN) do
                if bytes + #char > 32768 then break end
                parts[#parts + 1], bytes = char, bytes + #char
            end
            truncated = true
            return
        end
        parts[#parts + 1], bytes = text, bytes + #text
    end
    local walk
    walk = function(value, depth)
        if truncated then return end
        nodes = nodes + 1
        if nodes > 4096 or depth > 64 then truncated = true; return end
        if type(value) == "string" then append(value); return end
        if type(value) ~= "table" then append("[Unsupported content]"); return end
        if value.type == "image" or value.tag == "img" then append("[Image omitted]"); return end
        if value.type == "text" then append(value.text); return end
        if value.type == "structured-content" then walk(value.content, depth + 1); return end
        if value.tag == "br" then append("\n"); return end
        if value.tag then
            if value.tag == "rt" then append("(") end
            if value.content ~= nil then walk(value.content, depth + 1) else append("[Unsupported content]") end
            if value.tag == "rt" then append(")") end
            if value.tag == "div" or value.tag == "li" or value.tag == "tr" then append("\n") end
        elseif #value > 0 then
            for _, child in ipairs(value) do
                walk(child, depth + 1)
                if truncated then break end
            end
        else
            append("[Unsupported content]")
        end
    end
    for _, definition in ipairs(glossary) do
        if truncated then break end
        -- A top-level array is a formOf reference, not a display definition.
        if type(definition) ~= "table" or definition.type then
            walk(definition, 0)
            append("\n\n")
        end
    end
    if truncated then parts[#parts + 1] = "\n[Definition truncated]" end
    return table.concat(parts)
end

function Render.results(search_result)
    local results = {}
    for i = 1, math.min(#search_result.entries, 32) do
        local hit = search_result.entries[i]
        local entry = hit.entry
        local prefix = entry.reading ~= "" and (entry.reading .. "\n\n") or ""
        if #hit.state.reasons > 0 then prefix = prefix .. "Inflection: " .. table.concat(hit.state.reasons, " → ") .. "\n\n" end
        local definition = prefix .. Render.definition(entry.database:glossary(entry))
        if i == 32 and #search_result.entries > 32 then definition = definition .. "\n[Only the first 32 results are displayed]" end
        results[#results + 1] = {dict = entry.database.metadata.index.title, word = entry.term,
            definition = definition, is_html = false, provider_dictionary_id = entry.dictionary_id}
    end
    return results
end

return Render
