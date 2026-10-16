-- Specs for plugins/bookwords.koplugin: the word store and page matching,
-- with Yomitan's test dictionary for deinflection.
describe("Looked-up words", function()
    local Store, Matcher, util
    local translator

    -- Like Yomitan:matchAt() in plugins/yomitan.koplugin/main.lua.
    local function matchAt(text)
        local result = translator:findTerms(text, { match_only = true })
        local length = result.original_text_length
        if length == 0 then return end
        local words = {}
        for _, entry in ipairs(result.entries) do
            if entry.max_original_text_length == length then
                for _, headword in ipairs(entry.headwords) do
                    table.insert(words, { term = headword.term, reading = headword.reading })
                end
            end
        end
        return length, words
    end

    local function chars(text)
        return util.splitToChars(text)
    end

    setup(function()
        require("commonrequire")
        package.path = "plugins/bookwords.koplugin/?.lua;plugins/yomitan.koplugin/?.lua;" .. package.path
        Store = require("bookwords/store")
        Matcher = require("bookwords/matcher")
        util = require("util")
        local Dictionary = require("yomitan/db")
        local Translator = require("yomitan/translator")
        local dict = assert(Dictionary.open("spec/front/unit/yomitan/test_dictionary"))
        translator = Translator.new{ dictionaries = { dict }, json_decode = require("rapidjson").decode }
    end)

    it("saves and loads the words of a book", function()
        local saved = {}
        local doc_settings = {
            readSetting = function(_, key) return saved[key] end,
            saveSetting = function(_, key, value) saved[key] = value end,
            delSetting = function(_, key) saved[key] = nil end,
        }
        local store = Store.load(doc_settings)
        assert.is_true(store:isEmpty())
        store:add("打ち込む", "うちこむ", "打ち込んで")
        store:add("打ち込む", "うちこむ", "打ち込みます")
        store:save(doc_settings)
        local loaded = Store.load(doc_settings)
        assert.is_true(loaded:has("打ち込む", "うちこむ"))
        assert.are.equal(2, loaded:list()[1].count)
        loaded:clear()
        loaded:save(doc_settings)
        assert.is_nil(saved.bookwords)
    end)

    it("marks an inflected form of a looked-up word", function()
        local store = Store.new()
        store:add("打ち込む", "うちこむ", "打ち込む")
        local spans = Matcher.matchPage(chars("これは打ち込んでいる。"), store, matchAt)
        assert.are.equal(1, #spans)
        assert.are.equal(4, spans[1].start)
        assert.is_true(spans[1].length >= 5)
        assert.are.equal(Store.key("打ち込む", "うちこむ"), spans[1].key)
    end)

    it("does not mark a word inside a longer word that a lookup would show", function()
        local store = Store.new()
        store:add("打つ", "うつ", "打つ")
        local spans = Matcher.matchPage(chars("打ち込む"), store, matchAt)
        assert.are.equal(0, #spans)
    end)

    it("matches recorded forms literally without a dictionary or past the lookup cap", function()
        local store = Store.new()
        store:add("打ち込む", "うちこむ", "打ち込んで")
        local spans = Matcher.matchPage(chars("あ打ち込んで"), store, nil)
        assert.are.same({ { start = 2, length = 5, key = Store.key("打ち込む", "うちこむ") } }, spans)
        local calls
        spans, calls = Matcher.matchPage(chars("あ打ち込んで"), store, matchAt, { max_calls = 0 })
        assert.are.equal(0, calls)
        assert.are.equal(1, #spans)
    end)

    it("does not match across paragraphs", function()
        local store = Store.new()
        store:add("打ち込む", "うちこむ", "打ち込む")
        local page = chars("打ち")
        table.insert(page, Matcher.SEPARATOR)
        for _, c in ipairs(chars("込む")) do table.insert(page, c) end
        assert.are.equal(0, #Matcher.matchPage(page, store, nil))
    end)
end)
