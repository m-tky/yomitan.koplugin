local JSON = require("rapidjson")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local Database = {}
local APPLICATION_ID = 0x594F4D49
local MAX_MATCHES = 4096
local COLUMNS = {
    metadata = {"key", "value"},
    entries = {"id", "source_bank", "source_row", "term", "reading", "definition_tags", "rules", "score",
        "glossary_json", "sequence", "term_tags", "definition_count", "form_count"},
    lookup_keys = {"key", "entry_id"}, tags = {"name", "raw_json"},
    form_links = {"entry_id", "glossary_position", "target_term", "inflection_rules_json"},
    assets = {"archive_path", "relative_path", "media_type", "byte_size", "sha256"},
}

local function allRows(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = {}
    for row in stmt:rows() do
        assert(#rows < 128, "Oversized dictionary schema/metadata")
        rows[#rows + 1] = row
    end
    stmt:close()
    return rows
end

local function decode(text)
    assert(type(text) == "string" and #text <= 4 * 1024 * 1024, "Oversized or invalid dictionary JSON")
    return JSON.decode(text)
end

function Database.open(path, expected_id)
    for _, suffix in ipairs({"-wal", "-shm", "-journal"}) do
        assert(not lfs.symlinkattributes(path .. suffix), "Yomitan bundles must not have SQLite journal sidecars; reimport the dictionary")
    end
    local file = assert(io.open(path, "rb"))
    local header = file:read(20)
    file:close()
    assert(header and header:sub(1, 16) == "SQLite format 3\0" and header:byte(17) == 16 and header:byte(18) == 0
        and header:byte(19) == 1 and header:byte(20) == 1,
        "Yomitan bundles must use a finalized 4096-byte-page rollback-journal database")
    local conn = SQ3.open(path, "ro")
    local ok, result = pcall(function()
        conn:exec("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=128; PRAGMA mmap_size=0;")
        assert(tonumber(conn:rowexec("PRAGMA application_id")) == APPLICATION_ID, "Not a Yomitan bundle database")
        assert(tonumber(conn:rowexec("PRAGMA user_version")) == 1, "Unsupported Yomitan database version")
        local found = {}
        for _, row in ipairs(allRows(conn, "SELECT type,name,tbl_name FROM sqlite_master")) do
            local automatic_index = row[1] == "index" and row[2]:match("^sqlite_autoindex_") and COLUMNS[row[3]]
            if not automatic_index then
                assert(row[1] == "table" and COLUMNS[row[2]], "Unexpected dictionary schema object")
                found[row[2]] = true
            end
        end
        for name, columns in pairs(COLUMNS) do
            assert(found[name], "Missing dictionary table: " .. name)
            local info = allRows(conn, "PRAGMA table_info(" .. name .. ")") -- fixed, trusted table name
            assert(#info == #columns, "Invalid dictionary columns: " .. name)
            for i, column in ipairs(columns) do
                assert(info[i][2] == column, "Invalid dictionary column: " .. column)
            end
        end
        local key_columns = allRows(conn, "PRAGMA table_info(lookup_keys)")
        assert(tonumber(key_columns[1][6]) == 1 and tonumber(key_columns[2][6]) == 2, "Missing exact-key index")
        local metadata = {}
        for _, row in ipairs(allRows(conn, "SELECT key,value FROM metadata")) do metadata[row[1]] = decode(row[2]) end
        assert(type(metadata.content_id) == "string" and metadata.content_id:match("^[a-f0-9]+$")
            and #metadata.content_id == 64, "Invalid dictionary identity")
        assert(not expected_id or expected_id == metadata.content_id, "Dictionary identity mismatch")
        assert(metadata.profile == "ja-terms-v3-text-v1" and type(metadata.index) == "table"
            and type(metadata.index.title) == "string", "Unsupported dictionary profile")
        return setmetatable({conn = conn, id = metadata.content_id, metadata = metadata, statements = {}}, {__index = Database})
    end)
    if not ok then conn:close(); error(result) end
    return result
end

function Database:statement(key, sql)
    assert(self.conn, "Dictionary database is closed")
    if not self.statements[key] then self.statements[key] = self.conn:prepare(sql) end
    return self.statements[key]:clearbind():reset()
end

function Database:lookup(words)
    assert(#words <= 512, "Too many dictionary query terms")
    local results, indices, matched = {}, {}, 0
    for i, word in ipairs(words) do
        assert(type(word) == "string" and #word <= 128, "Invalid dictionary query term")
        assert(not indices[word], "Dictionary lookup expects unique query terms")
        results[i], indices[word] = {}, i
    end
    for first = 1, #words, 128 do
        local last = math.min(first + 127, #words)
        local placeholders, bindings = {}, {}
        for i = first, last do placeholders[#placeholders + 1] = "?"; bindings[#bindings + 1] = words[i] end
        local key = #bindings == 128 and "keys_full" or "keys_partial"
        if key == "keys_partial" and self.partial_size ~= #bindings then
            if self.statements[key] then self.statements[key]:close(); self.statements[key] = nil end
            self.partial_size = #bindings
        end
        local stmt = self:statement(key,
            "SELECT k.key,e.id,e.term,e.reading,e.rules,e.score,e.sequence,e.definition_count,e.form_count " ..
            "FROM lookup_keys k JOIN entries e ON e.id=k.entry_id WHERE k.key IN (" .. table.concat(placeholders, ",") ..
            ") ORDER BY e.id LIMIT 4097")
        stmt:bind(unpack(bindings))
        for row in stmt:rows() do
            matched = matched + 1
            if matched > MAX_MATCHES then stmt:reset(); error("Too many exact dictionary matches") end
            local rules = {}
            assert(type(row[5]) == "string" and #row[5] <= 4096, "Invalid dictionary rule data")
            for rule in row[5]:gmatch("%S+") do rules[#rules + 1] = rule end
            local entry = {id = tonumber(row[2]), term = row[3], reading = row[4], rules = rules,
                score = tonumber(row[6]), sequence = tonumber(row[7]), definition_count = tonumber(row[8]),
                form_count = tonumber(row[9]), database = self, dictionary_id = self.id}
            table.insert(results[indices[row[1]]], entry)
        end
    end
    return results
end

function Database:forms(entry)
    if entry.form_count == 0 then return {} end
    local stmt = self:statement("forms", "SELECT target_term,inflection_rules_json FROM form_links WHERE entry_id=? ORDER BY glossary_position")
    stmt:bind(entry.id)
    local forms = {}
    for row in stmt:rows() do
        forms[#forms + 1] = {term = row[1], reasons = decode(row[2])}
        assert(#forms <= 512, "Too many dictionary form links")
    end
    return forms
end

function Database:glossary(entry)
    local stmt = self:statement("glossary", "SELECT CASE WHEN length(CAST(glossary_json AS BLOB))<=4194304 THEN glossary_json ELSE NULL END FROM entries WHERE id=?")
    stmt:bind(entry.id)
    local row = stmt:step()
    stmt:reset()
    assert(row and type(row[1]) == "string", "Missing or oversized dictionary definition")
    return decode(row[1])
end

function Database:close()
    if self.conn then self.conn:close(); self.conn = nil; self.statements = {} end
end

return Database
