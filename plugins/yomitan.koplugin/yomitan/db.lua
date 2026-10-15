--[[--
Read-only access to a converted Yomitan dictionary.

A dictionary is a folder produced by tools/yomitan_convert.py:

    <folder>/dict.sqlite3   terms, tags, metadata and compressed glossaries
    <folder>/styles.css     optional dictionary stylesheet
    <folder>/media/...      images, at their original paths inside the zip

Glossaries (JSON) are stored in zlib-compressed blocks of consecutive rows,
one glossary per line.

@module yomitan.db
]]

local SQ3 = require("lua-ljsqlite3/init")
local ffi = require("ffi")

local SCHEMA_VERSION = 1
local CHUNK_SIZE = 400 -- bound parameters per statement
local BLOCK_CACHE_SIZE = 32 -- decompressed glossary blocks kept per dictionary

local Dictionary = {}
Dictionary.__index = Dictionary
Dictionary.SCHEMA_VERSION = SCHEMA_VERSION

local zlib

local function inflate(data, size)
    if not zlib then
        zlib = require("ffi/zlib")
    end
    return zlib.zlib_uncompress(data, size)
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- KOReader's lua-ljsqlite3 returns BLOBs as {pointer, size} (only valid until
-- the next step/reset); upstream returns Lua strings.
local function blobToString(blob)
    if type(blob) == "table" then
        return ffi.string(blob[1], blob[2])
    end
    return blob
end

--- Open the dictionary in folder `dir`.
-- @treturn Dictionary|nil
-- @treturn string error message on failure
function Dictionary.open(dir)
    local db_path = dir .. "/dict.sqlite3"
    local f = io.open(db_path, "rb")
    if not f then
        return nil, "missing dict.sqlite3"
    end
    f:close()
    local ok, conn = pcall(SQ3.open, db_path, "ro")
    if not ok or not conn then
        return nil, "cannot open database: " .. tostring(conn)
    end
    local version = tonumber(conn:rowexec("PRAGMA user_version;"))
    if version ~= SCHEMA_VERSION then
        conn:close()
        return nil, string.format("unsupported database version %s (expected %d); re-run tools/yomitan_convert.py", tostring(version), SCHEMA_VERSION)
    end
    local o = setmetatable({
        dir = dir,
        conn = conn,
        meta = {},
        statements = {},
        block_cache = {},
        block_cache_order = {},
    }, Dictionary)
    local stmt = conn:prepare("SELECT key, value FROM meta;")
    local row = stmt:step()
    while row do
        o.meta[row[1]] = row[2]
        row = stmt:step()
    end
    stmt:close()
    o.title = o.meta.title or dir:match("([^/]+)/*$")
    o.revision = o.meta.revision
    o.styles = readFile(dir .. "/styles.css")
    o.media_dir = dir .. "/media"
    return o
end

function Dictionary:close()
    for _, stmt in pairs(self.statements) do
        stmt:close()
    end
    self.statements = {}
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function Dictionary:_getStatement(column, n)
    local key = column .. n
    local stmt = self.statements[key]
    if not stmt then
        local placeholders = string.rep("?,", n - 1) .. "?"
        stmt = self.conn:prepare(string.format(
            "SELECT id, expression, reading, definition_tags, rules, score, sequence, term_tags, glossary_block, glossary_index FROM terms WHERE %s IN (%s);",
            column, placeholders))
        self.statements[key] = stmt
    end
    return stmt
end

--- Glossary lines of a block (decompressed and split), cached.
function Dictionary:_getBlock(block_id)
    local lines = self.block_cache[block_id]
    if lines then return lines end
    local stmt = self.statements.block
    if not stmt then
        stmt = self.conn:prepare("SELECT size, data FROM glossary_blocks WHERE id = ?;")
        self.statements.block = stmt
    end
    stmt:reset()
    local row = stmt:bind(block_id):step()
    lines = {}
    if row then
        local size = tonumber(row[1])
        local data = inflate(blobToString(row[2]), size)
        for line in data:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
    end
    stmt:clearbind()
    table.insert(self.block_cache_order, block_id)
    self.block_cache[block_id] = lines
    if #self.block_cache_order > BLOCK_CACHE_SIZE then
        self.block_cache[table.remove(self.block_cache_order, 1)] = nil
    end
    return lines
end

--- Find rows whose expression (index_index 0) or reading (index_index 1)
-- equals one of `terms`. Each row carries `item_index`, the 1-based index of
-- the matching term, and its glossary as JSON text (`glossary`).
function Dictionary:findTermsBulk(terms)
    local index_of = {}
    for i, term in ipairs(terms) do
        if index_of[term] == nil then index_of[term] = i end
    end
    local results = {}
    for index_index, column in ipairs({"expression", "reading"}) do
        for start = 1, #terms, CHUNK_SIZE do
            local n = math.min(CHUNK_SIZE, #terms - start + 1)
            local stmt = self:_getStatement(column, n)
            stmt:reset()
            stmt:bind(unpack(terms, start, start + n - 1))
            local row = stmt:step()
            while row do
                local key = index_index == 1 and row[2] or row[3]
                table.insert(results, {
                    rowid = tonumber(row[1]),
                    expression = row[2],
                    reading = row[3],
                    definition_tags = row[4],
                    rules = row[5],
                    score = tonumber(row[6]) or 0,
                    sequence = tonumber(row[7]) or -1,
                    term_tags = row[8],
                    glossary_block = tonumber(row[9]),
                    glossary_index = tonumber(row[10]),
                    item_index = index_of[key],
                    index_index = index_index - 1,
                })
                row = stmt:step()
            end
            stmt:clearbind()
        end
    end
    for _, r in ipairs(results) do
        r.glossary = self:_getBlock(r.glossary_block)[r.glossary_index + 1] or "[]"
    end
    return results
end

--- First tag row named `name`, as Yomitan's findTagMetaBulk returns.
function Dictionary:findTagMeta(name)
    local stmt = self.statements.tag
    if not stmt then
        stmt = self.conn:prepare("SELECT category, ord, notes, score FROM tags WHERE name = ? ORDER BY id LIMIT 1;")
        self.statements.tag = stmt
    end
    stmt:reset()
    local row = stmt:bind(name):step()
    local tag
    if row then
        tag = {
            category = row[1],
            order = tonumber(row[2]) or 0,
            notes = row[3],
            score = tonumber(row[4]) or 0,
        }
    end
    stmt:clearbind()
    return tag
end

--- Number of term rows (for the dictionary list).
function Dictionary:countTerms()
    return tonumber(self.conn:rowexec("SELECT COUNT(*) FROM terms;")) or 0
end

return Dictionary
