--[[--
Word list for keeping Japanese words together at column breaks.

crengine (JpWordList, in jpwords.cpp) segments text into dictionary words to
avoid splitting them across columns (see doc/Japanese_line_breaking.md). This
module builds its word list, `words.tsv` in the Yomitan data folder, from the
enabled dictionaries: one line per expression or reading,

    key <TAB> parts of speech <TAB> flags

sorted by bytes, with flags drawn from:

    p  particle, auxiliary or copula: definition tags prt, aux, aux-v, aux-adj or cop
    x  idiom only: every entry with this expression is tagged exp
    c  common: term tags contain ⭐ (JMdict priority)
    w  written this way: an expression, or the reading of an entry tagged uk

Rows tagged `forms` are skipped and keys longer than 16 chars are dropped.
The list is rebuilt only when the enabled dictionaries change.

@module yomitan.wordlist
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

local FORMAT = 1 -- bump when the file format or the flags change
local MAX_KEY_LENGTH = 16 -- JpWords::MAX_WORD_LENGTH
local WRITE_CHUNK = 4096 -- lines per write

-- Per key: rules concatenated (with duplicates), and the flag inputs.
local SQL = [[
SELECT key, group_concat(rules, ' '), max(common), max(written), max(attach), min(exp), max(is_expr)
FROM (
    SELECT expression AS key, rules, instr(term_tags, '⭐') > 0 AS common, 1 AS written,
        (instr(t, ' prt ') OR instr(t, ' aux ') OR instr(t, ' aux-v ')
            OR instr(t, ' aux-adj ') OR instr(t, ' cop ')) AS attach,
        instr(t, ' exp ') > 0 AS exp, 1 AS is_expr
    FROM (SELECT *, ' ' || definition_tags || ' ' AS t FROM terms)
    WHERE instr(t, ' forms ') = 0
    UNION ALL
    SELECT reading, rules, instr(term_tags, '⭐') > 0, instr(t, ' uk ') > 0, 0, 1, 0
    FROM (SELECT *, ' ' || definition_tags || ' ' AS t FROM terms)
    WHERE reading <> expression AND instr(t, ' forms ') = 0
) GROUP BY key ORDER BY key;
]]

local WordList = {}

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- Byte order, as SQLite sorts the keys (Lua's < depends on the locale).
local function lessBytes(a, b)
    if a == b then return false end
    for i = 1, math.min(#a, #b) do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

local function isTrue(value)
    return value ~= nil and tonumber(value) ~= 0
end

local function charCount(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Signature of the dictionaries the list is built from.
function WordList.signature(dictionaries)
    local parts = {}
    for _, dict in ipairs(dictionaries) do
        local attr = lfs.attributes(dict.dir .. "/dict.sqlite3") or {}
        table.insert(parts, string.format("%s %s %s", dict.dir, tostring(attr.size), tostring(attr.modification)))
    end
    table.sort(parts) -- the union does not depend on the dictionary order
    table.insert(parts, 1, "format " .. FORMAT)
    return table.concat(parts, "\n")
end

--- Write the word list of `dictionaries` to `path`, replacing it atomically.
-- @treturn int|nil number of keys
-- @treturn string error message on failure
function WordList.build(dictionaries, path)
    local cursors = {}
    local function closeAll()
        for _, cursor in ipairs(cursors) do cursor.stmt:close() end
        cursors = {}
    end
    for _, dict in ipairs(dictionaries) do
        local ok, stmt = pcall(dict.conn.prepare, dict.conn, SQL)
        if not ok then
            closeAll()
            return nil, tostring(stmt)
        end
        local row = stmt:step()
        if row then
            table.insert(cursors, { stmt = stmt, row = row })
        else
            stmt:close()
        end
    end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then
        closeAll()
        return nil, err
    end
    local count = 0
    local lines = {}
    while #cursors > 0 do
        -- Merge the dictionaries' sorted keys.
        local key = cursors[1].row[1]
        for i = 2, #cursors do
            if lessBytes(cursors[i].row[1], key) then key = cursors[i].row[1] end
        end
        local rules = {}
        local particle, idiom, has_expression, common, written = false, true, false, false, false
        for i = #cursors, 1, -1 do
            local cursor = cursors[i]
            local row = cursor.row
            if row[1] == key then
                for rule in (row[2] or ""):gmatch("%S+") do rules[rule] = true end
                common = common or isTrue(row[3])
                written = written or isTrue(row[4])
                if isTrue(row[7]) then
                    has_expression = true
                    particle = particle or isTrue(row[5])
                    idiom = idiom and isTrue(row[6])
                end
                cursor.row = cursor.stmt:step()
                if not cursor.row then
                    cursor.stmt:close()
                    table.remove(cursors, i)
                end
            end
        end
        if charCount(key) <= MAX_KEY_LENGTH then
            local list = {}
            for rule in pairs(rules) do table.insert(list, rule) end
            table.sort(list)
            local flags = (has_expression and particle and "p" or "")
                .. (has_expression and idiom and "x" or "")
                .. (common and "c" or "")
                .. (written and "w" or "")
            table.insert(lines, key .. "\t" .. table.concat(list, " ") .. "\t" .. flags .. "\n")
            count = count + 1
            if #lines >= WRITE_CHUNK then
                f:write(table.concat(lines))
                lines = {}
            end
        end
    end
    f:write(table.concat(lines))
    f:close()
    if not os.rename(tmp, path) then
        os.remove(path)
        local ok, rename_err = os.rename(tmp, path)
        if not ok then return nil, rename_err end
    end
    return count
end

--- Make sure `<dir>/words.tsv` matches the dictionaries, rebuilding it if needed.
-- @treturn string|nil path of the word list
-- @treturn string signature of the dictionaries it was built from
function WordList.update(dictionaries, dir)
    if #dictionaries == 0 then return nil end
    local path = dir .. "/words.tsv"
    local signature_path = dir .. "/words.sig"
    local signature = WordList.signature(dictionaries)
    if readFile(signature_path) ~= signature or lfs.attributes(path, "mode") ~= "file" then
        local start_time = time.now()
        os.remove(signature_path)
        local count, err = WordList.build(dictionaries, path)
        if not count then
            logger.warn("yomitan: cannot build the word list:", err)
            return nil
        end
        writeFile(signature_path, signature)
        logger.info("yomitan: built word list with", count, "keys in",
            time.to_s(time.now() - start_time), "seconds")
    end
    return path, signature
end

return WordList
