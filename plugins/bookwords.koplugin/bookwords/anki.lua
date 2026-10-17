--[[--
Sends looked-up words to Anki through the AnkiConnect add-on
(https://ankiweb.net/shared/info/2055492159), over the local network.

Notes use their own note type, created in Anki on first use.

@module bookwords.anki
]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local Anki = {}

Anki.MODEL = "KOReader BookWords"
Anki.DEFAULT_DECK = "KOReader"
Anki.PORT = 8765

local FIELDS = { "Word", "Reading", "Sentence", "Definition", "Book" }

local CSS = [[
.card { font-family: sans-serif; font-size: 22px; text-align: center; }
.word { font-size: 44px; }
.sentence { margin-top: 0.8em; }
.reading { font-size: 28px; }
.definition { margin-top: 0.8em; text-align: left; font-size: 18px; }
.book { margin-top: 1em; font-size: 14px; color: gray; }
]]

local FRONT = [[
<div class="word">{{Word}}</div>
<div class="sentence">{{Sentence}}</div>
]]

local BACK = [[
{{FrontSide}}
<hr id="answer">
<div class="reading">{{Reading}}</div>
<div class="definition">{{Definition}}</div>
<div class="book">{{Book}}</div>
]]

--- "192.168.1.5" → "http://192.168.1.5:8765"
function Anki.normalizeUrl(url)
    url = util.trim(url or "")
    if url == "" then return end
    if not url:match("^https?://") then
        url = "http://" .. url
    end
    if not url:match("^https?://[^/]+:%d+") then
        url = url:gsub("^(https?://[^/]+)", "%1:" .. Anki.PORT, 1)
    end
    return url
end

local function request(url, action, params)
    local body = JSON.encode({ action = action, version = 6, params = params })
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if headers == nil or code ~= 200 then
        logger.warn("bookwords: AnkiConnect", action, "failed:", status or code)
        return nil, tostring(status or code)
    end
    local ok, response = pcall(JSON.decode, table.concat(sink))
    if not ok or type(response) ~= "table" then
        return nil, "invalid response from AnkiConnect"
    end
    if type(response.error) == "string" then
        return nil, response.error
    end
    return response.result
end

local function html(text)
    return (util.htmlEscape(text or ""):gsub("\n", "<br>"))
end

local function sentenceHtml(sentence, word)
    local s, e
    if word and word ~= "" then
        s, e = sentence:find(word, 1, true)
    end
    if not s then
        return html(sentence)
    end
    return html(sentence:sub(1, s - 1)) .. "<b>" .. html(word) .. "</b>" .. html(sentence:sub(e + 1))
end

local function ensureModelAndDeck(url, deck)
    local models, err = request(url, "modelNames")
    if not models then return nil, err end
    local has_model = false
    for _, name in ipairs(models) do
        if name == Anki.MODEL then has_model = true break end
    end
    if not has_model then
        local _, model_err = request(url, "createModel", {
            modelName = Anki.MODEL,
            inOrderFields = FIELDS,
            css = CSS,
            isCloze = false,
            cardTemplates = { { Name = "Recognition", Front = FRONT, Back = BACK } },
        })
        if model_err then return nil, model_err end
    end
    local _, deck_err = request(url, "createDeck", { deck = deck })
    if deck_err then return nil, deck_err end
    return true
end

--- Add a note for each word ({term, reading, sentence, sentence_word,
-- definition, book}) to `deck`, skipping the ones already in Anki.
-- @treturn table|nil for each word, whether it is in Anki now
-- @treturn int|string number of notes added, or the error
function Anki.addWords(url, deck, words)
    local ok, err = ensureModelAndDeck(url, deck)
    if not ok then return nil, err end
    local notes = {}
    for i, word in ipairs(words) do
        notes[i] = {
            deckName = deck,
            modelName = Anki.MODEL,
            fields = {
                Word = html(word.term),
                Reading = html(word.reading),
                Sentence = word.sentence and sentenceHtml(word.sentence, word.sentence_word) or "",
                Definition = html(word.definition),
                Book = html(word.book),
            },
            options = { allowDuplicate = false, duplicateScope = "deck" },
            tags = { "koreader" },
        }
    end
    -- Notes that cannot be added are duplicates: their Word is in the deck.
    local can_add
    can_add, err = request(url, "canAddNotes", { notes = notes })
    if not can_add then return nil, err end
    local in_anki, to_add, indices = {}, {}, {}
    for i = 1, #notes do
        if can_add[i] == true then
            table.insert(to_add, notes[i])
            table.insert(indices, i)
        else
            in_anki[i] = true
        end
    end
    local added = 0
    if #to_add > 0 then
        local ids
        ids, err = request(url, "addNotes", { notes = to_add })
        if not ids then return nil, err end
        for j, i in ipairs(indices) do
            if type(ids[j]) == "number" then
                in_anki[i] = true
                added = added + 1
            end
        end
    end
    return in_anki, added
end

return Anki
