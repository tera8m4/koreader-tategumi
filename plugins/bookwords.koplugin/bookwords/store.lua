--[[--
The words looked up in one book, kept in the book's sidecar settings.

A word is a dictionary entry (term and reading); the surface forms that were
looked up (e.g. 食べさせられた for 食べる) are kept too, for matching when no
deinflecting dictionary is available.

@module bookwords.store
]]

local util = require("util")

local SETTINGS_KEY = "bookwords"

local Store = {}
Store.__index = Store

function Store.key(term, reading)
    return term .. "\t" .. (reading or "")
end

local function firstChar(s)
    return s:match("^" .. util.UTF8_CHAR_PATTERN)
end

local function charCount(s)
    local n = 0
    for _ in s:gmatch(util.UTF8_CHAR_PATTERN) do n = n + 1 end
    return n
end

function Store.new(words)
    -- version changes whenever the words do, so that views can cache.
    return setmetatable({ words = words or {}, version = 0 }, Store)
end

function Store.load(doc_settings)
    return Store.new(doc_settings:readSetting(SETTINGS_KEY))
end

function Store:save(doc_settings)
    if next(self.words) then
        doc_settings:saveSetting(SETTINGS_KEY, self.words)
    else
        doc_settings:delSetting(SETTINGS_KEY)
    end
end

function Store:_changed()
    self.version = self.version + 1
    self.first_chars = nil
end

--- Record a lookup of `surface` (looked up as `term`, `reading`), found in
-- `sentence` if known.
function Store:add(term, reading, surface, sentence)
    local key = Store.key(term, reading)
    local word = self.words[key]
    if not word then
        word = { term = term, reading = reading or "", surfaces = {}, count = 0 }
        self.words[key] = word
    end
    word.count = word.count + 1
    word.last = os.time()
    if surface and surface ~= "" then
        word.surfaces[surface] = true
    end
    if sentence and sentence ~= "" then
        word.sentence, word.sentence_word = sentence, surface
    end
    self:_changed()
    return key
end

function Store:has(term, reading)
    return self.words[Store.key(term, reading)] ~= nil
end

function Store:remove(key)
    self.words[key] = nil
    self:_changed()
end

function Store:clear()
    self.words = {}
    self:_changed()
end

function Store:isEmpty()
    return next(self.words) == nil
end

--- Words, most looked-up first (then most recent), each with its key.
function Store:list()
    local list = {}
    for key, word in pairs(self.words) do
        table.insert(list, { key = key, term = word.term, reading = word.reading, count = word.count, last = word.last or 0 })
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.last ~= b.last then return a.last > b.last end
        return a.key < b.key
    end)
    return list
end

--- Words not sent to Anki yet, in list() order: {key, word} pairs.
function Store:unsent()
    local out = {}
    for _, item in ipairs(self:list()) do
        local word = self.words[item.key]
        if not word.anki then
            table.insert(out, { key = item.key, word = word })
        end
    end
    return out
end

function Store:markSent(key)
    local word = self.words[key]
    if word then word.anki = true end
end

local function forms(word)
    local out = { word.term }
    if word.reading ~= "" then table.insert(out, word.reading) end
    for surface in pairs(word.surfaces) do table.insert(out, surface) end
    return out
end

--- Set of the characters any recorded word can start with: only positions
-- starting with one of these need to be checked.
function Store:firstChars()
    if not self.first_chars then
        local set = {}
        for _, word in pairs(self.words) do
            for _, form in ipairs(forms(word)) do
                local c = firstChar(form)
                if c then set[c] = true end
            end
        end
        self.first_chars = set
    end
    return self.first_chars
end

--- Longest recorded term, reading or surface form that `text` starts with.
-- @treturn int|nil length in characters
-- @treturn string key of the word
function Store:matchSurface(text)
    local best_bytes, best_key = 0, nil
    for key, word in pairs(self.words) do
        for _, form in ipairs(forms(word)) do
            if #form > best_bytes and text:sub(1, #form) == form then
                best_bytes, best_key = #form, key
            end
        end
    end
    if best_key then
        return charCount(text:sub(1, best_bytes)), best_key
    end
end

return Store
