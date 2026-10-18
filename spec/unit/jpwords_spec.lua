-- Segmentation and split costs of crengine's JpWords, used to keep Japanese
-- words together at column breaks (doc/Japanese_line_breaking.md).
describe("JpWords", function()
    local cre

    setup(function()
        require("commonrequire")
        cre = require("libs/libkoreader-cre")
        cre.jpSetDeinflectRules(dofile("plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua"))
        assert.is_true(cre.jpSetDictionaries({"spec/front/unit/yomitan/jpwords_dictionary/dict.sqlite3"}))
    end)

    teardown(function()
        cre.jpSetDictionaries({})
    end)

    it("picks the cheapest path rather than the longest match", function()
        -- Yomitan's longest match would read 沈めてい as a form of 沈めている.
        local seg = cre.jpSegment("沈めていくと")
        assert.are.same({"沈めて", "いく", "と"}, seg.words)
        assert.are.same({"沈めて", "いくと"}, seg.units)
        assert.are.equal(0, seg.costs[3]) -- 沈めて|いくと
        assert.are.equal(20, seg.costs[4]) -- 沈めてい|くと
    end)

    it("keeps an inflected word whole", function()
        local seg = cre.jpSegment("二階から飛び降りて")
        assert.are.same({"二階", "から", "飛び降りて"}, seg.words)
        assert.are.same({"二階から", "飛び降りて"}, seg.units)
        assert.are.equal(0, seg.costs[4]) -- 二階から|飛び降りて
        -- Fewer than 3 letters on a side.
        assert.are.equal(20, seg.costs[5]) -- 飛|び降りて
        assert.are.equal(20, seg.costs[6]) -- 飛び|降りて
        assert.are.equal(20, seg.costs[7]) -- 飛び降|りて
    end)

    it("prefers a common entry written this way", function()
        -- いない is いる, not a kana spelling of 居ない.
        assert.are.same({"いない"}, cre.jpSegment("いない").words)
        local found = false
        for _, result in ipairs(cre.jpDeinflect("いない")) do
            if result.text == "いる" then found = true end
        end
        assert.is_true(found)
    end)

    it("takes an unknown katakana run as one word", function()
        local seg = cre.jpSegment("メロスは激怒した。")
        assert.are.same({"メロス", "は", "激怒", "した。"}, seg.words)
        assert.are.same({"メロスは", "激怒した。"}, seg.units)
        assert.are.equal(0, seg.costs[4]) -- メロスは|激怒した。
    end)

    it("counts letters up to the punctuation", function()
        -- Only だ would stay after the break: 救うの|だ。」と
        local seg = cre.jpSegment("「救うのだ。」と")
        assert.are.same({"「救う", "のだ。」と"}, seg.units) -- のだ is an expression
        assert.are.equal(20, seg.costs[4])
    end)

    it("keeps idioms as one word", function()
        local seg = cre.jpSegment("腰を抜かした事がある。")
        assert.are.same({"腰を抜かした", "事がある。"}, seg.units)
        assert.are.equal(20, seg.costs[2]) -- 腰を|抜かした
        assert.are.equal(0, seg.costs[6]) -- 腰を抜かした|事がある。
    end)
end)
