-- Adapted from the pinned Yomitan Translator (GPL-3.0-or-later).
-- Copyright (C) 2023-2026 Yomitan Authors; Copyright (C) 2016-2022 Yomichan Authors.
local Transformer = require("yomitan/transformer")
local util = require("util")

local Search = {}
local PUNCTUATION = "「」『』【】・･、､,。｡.！!？?　 \t\r\n"

function Search.isWord(text)
    if not text then return false end
    for char in text:gmatch(util.UTF8_CHAR_PATTERN) do
        if not util.isCJKChar(char) or PUNCTUATION:find(char, 1, true) then return false end
    end
    return true
end

local function group(states)
    local words, groups = {}, {}
    assert(#states <= 8192, "Too many Yomitan derivations")
    for _, state in ipairs(states) do
        if state.term ~= "" then
            assert(#state.term <= 128, "Yomitan query exceeds the transport limit")
            if not groups[state.term] then
                assert(#words < 512, "Too many Yomitan query terms")
                words[#words + 1], groups[state.term] = state.term, {}
            end
            table.insert(groups[state.term], state)
        end
    end
    return words, groups
end

local function match(states, databases, filter)
    local words, groups = group(states)
    local matched, count = {}, 0
    if #words == 0 then return matched end
    for priority, database in ipairs(databases) do
        local results = database:lookup(words)
        for i, word in ipairs(words) do
            for _, entry in ipairs(results[i] or {}) do
                count = count + 1
                assert(count <= 4096, "Too many Yomitan dictionary matches")
                local flags = Transformer.dictionaryConditions(entry.rules)
                for _, state in ipairs(groups[word]) do
                    if filter == false or Transformer.conditionsMatch(state.conditions, flags) then
                        assert(#matched < 8192, "Too many Yomitan matched derivations")
                        matched[#matched + 1] = {entry = entry, state = state, priority = priority}
                    end
                end
            end
        end
    end
    return matched
end

function Search.find(text, databases, limit, options)
    options = options or {}
    limit = math.min(limit or 20, 32)
    local chars = {}
    for char in text:gmatch(util.UTF8_CHAR_PATTERN) do
        if #chars >= limit or not Search.isWord(char) then break end
        chars[#chars + 1] = char
    end
    local states = {}
    for count = #chars, 1, -1 do
        local source = table.concat(chars, "", 1, count)
        local candidates, err = Transformer.transform(source)
        assert(candidates, err)
        for _, candidate in ipairs(candidates) do
            assert(#states < 8192, "Too many Yomitan derivations")
            states[#states + 1] = {term = candidate.term, conditions = candidate.conditions,
                reasons = candidate.reasons, trace = candidate.trace, original = source, length = count}
        end
    end
    local algorithm_matches = match(states, databases, options.parts_of_speech_filter)
    local form_states = {}
    -- Dictionary-provided deinflections get one additional pass, as in
    -- Translator._getDictionaryDeinflections, not arbitrary recursive expansion.
    for _, hit in ipairs(algorithm_matches) do
        for _, form in ipairs(hit.entry.database:forms(hit.entry)) do
            assert(#form_states < 8192, "Too many dictionary-provided deinflections")
            local reasons = {}
            for _, reason in ipairs(hit.state.reasons) do reasons[#reasons + 1] = reason end
            for _, reason in ipairs(form.reasons) do reasons[#reasons + 1] = reason end
            form_states[#form_states + 1] = {term = form.term, conditions = 0, reasons = reasons,
                original = hit.state.original, length = hit.state.length}
        end
    end
    local dictionary_matches = match(form_states, databases, options.parts_of_speech_filter)
    local results, by_id, original_length = {}, {}, 0
    local function add(hits)
        for _, hit in ipairs(hits) do
            -- Reference filters out entries with only formOf arrays before
            -- computing originalTextLength. Keeping them would over-select text.
            if hit.entry.definition_count > 0 then
                original_length = math.max(original_length, hit.state.length)
                local id = hit.entry.dictionary_id .. ":" .. hit.entry.id
                local previous = by_id[id]
                if not previous then
                    results[#results + 1], by_id[id] = hit, hit
                elseif hit.state.length > previous.state.length then
                    previous.state = hit.state
                end
            end
        end
    end
    add(algorithm_matches)
    add(dictionary_matches)
    -- Display ordering is deliberately basic; source length above is independent
    -- of popup rank. Frequency dictionaries and merged browser UI are not ported.
    table.sort(results, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.entry.score ~= b.entry.score then return a.entry.score > b.entry.score end
        return a.entry.id < b.entry.id
    end)
    return {entries = results, originalTextLength = original_length}
end

function Search.select(args, databases, limit)
    limit = math.min(limit or 20, 32)
    local pos, text, positions, previous = args.pos0, "", {}, 0
    for _ = 1, limit * 2 do
        local next_pos = args.callbacks.get_next_char_pos(pos)
        if not next_pos or next_pos == pos then break end
        local candidate = args.callbacks.get_text_in_range(args.pos0, next_pos)
        if not Search.isWord(candidate) then break end
        local count = #util.splitToChars(candidate)
        if count > limit or count < previous then break end
        if count > previous then positions[count], text, previous = next_pos, candidate, count end
        pos = next_pos
        if count == limit then break end
    end
    if text == "" then return end
    local result = Search.find(text, databases, limit)
    local finish = positions[result.originalTextLength]
    if finish then return {args.pos0, finish} end
end

return Search
