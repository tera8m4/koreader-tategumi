-- Specs for plugins/yomitan.koplugin, checked against Yomitan's own test data
-- (see spec/unit/yomitan/README.md).
describe("Yomitan", function()
    local fixtures = "spec/front/unit/yomitan/"
    local Html, Japanese, LanguageTransformer, Scanner, Translator, Dictionary

    setup(function()
        require("commonrequire")
        package.path = "plugins/yomitan.koplugin/?.lua;" .. package.path
        Html = require("yomitan/html")
        Japanese = require("yomitan/japanese")
        LanguageTransformer = require("yomitan/language_transformer")
        Scanner = require("yomitan/scanner")
        Translator = require("yomitan/translator")
        Dictionary = require("yomitan/db")
    end)

    describe("language transformer", function()
        local transformer

        setup(function()
            transformer = LanguageTransformer.new()
            transformer:addDescriptor(require("yomitan/data/transforms_ja"))
        end)

        -- Same check as Yomitan's test/fixtures/language-transformer-test.js.
        local function hasTermReasons(source, term, rule, reasons)
            for _, result in ipairs(transformer:transform(source)) do
                if result.text == term then
                    local ok = true
                    if rule then
                        ok = LanguageTransformer.conditionsMatch(result.conditions, transformer:getConditionFlagsFromConditionType(rule))
                    end
                    if ok and reasons then
                        if #result.trace ~= #reasons then
                            ok = false
                        else
                            for i, reason in ipairs(reasons) do
                                if result.trace[i].transform ~= reason then
                                    ok = false
                                    break
                                end
                            end
                        end
                    end
                    if ok then return true end
                end
            end
            return false
        end

        it("passes Yomitan's Japanese deinflection tests", function()
            local failures = {}
            local total = 0
            for _, category in ipairs(dofile(fixtures .. "transform_cases.lua")) do
                for _, case in ipairs(category.tests) do
                    total = total + 1
                    local term, source, rule, reasons = case[1], case[2], case[3] or nil, case[4] or nil
                    if hasTermReasons(source, term, rule, reasons) ~= category.valid then
                        table.insert(failures, string.format("%s: %s -> %s", category.category, source, term))
                    end
                end
            end
            assert.are.equal(1446, total)
            assert.are.same({}, failures)
        end)

        it("records the inflection chain from the stem outwards", function()
            local found
            for _, result in ipairs(transformer:transform("食べさせられた")) do
                if result.text == "食べる" then
                    found = {}
                    for i, frame in ipairs(result.trace) do found[i] = frame.transform end
                    break
                end
            end
            assert.are.same({"causative", "potential or passive", "-た"}, found)
        end)

        it("maps dictionary parts of speech to condition flags", function()
            local v5 = transformer:getConditionFlagsFromPartsOfSpeech({"v5"})
            assert.is_true(LanguageTransformer.conditionsMatch(transformer:getConditionFlagsFromConditionType("v5d"), v5))
            assert.are.equal(0, transformer:getConditionFlagsFromPartsOfSpeech({"n", "unknown"}))
        end)
    end)

    describe("text preprocessors", function()
        it("convert like Yomitan's descriptions", function()
            assert.are.equal("ヨミチャン", Japanese.convertHalfWidthKanaToFullWidth("ﾖﾐﾁｬﾝ"))
            assert.are.equal("ダイジョウブ", Japanese.convertHalfWidthKanaToFullWidth("ﾀﾞｲｼﾞｮｳﾌﾞ"))
            assert.are.equal("よみちゃん", Japanese.convertAlphabeticToKana("yomichan"))
            assert.are.equal("ド", Japanese.normalizeCombiningCharacters("ト\u{3099}"))
            -- NFKD, so the handakuten stays a combining mark (as in Yomitan).
            assert.are.equal("アハ\u{309A}ート", Japanese.normalizeCJKCompatibilityCharacters("㌀"))
            assert.are.equal("一", Japanese.normalizeRadicals("⼀"))
            assert.are.equal("yomitan", Japanese.convertFullWidthAlphanumericToNormal("ｙｏｍｉｔａｎ"))
            assert.are.equal("ヨミチャン", Japanese.convertHiraganaToKatakana("よみちゃん"))
            assert.are.equal("かあな", Japanese.convertKatakanaToHiragana("カーナ"))
            assert.are.equal("すっごーい", Japanese.collapseEmphaticSequences("すっっごーーい", false))
            assert.are.equal("すごい", Japanese.collapseEmphaticSequences("すっっごーーい", true))
            assert.are.equal("万", Japanese.convertKanjiVariants("萬"))
        end)

        it("always return the unchanged text first", function()
            for _, processor in ipairs(Japanese.TEXT_PREPROCESSORS) do
                assert.are.equal("テスト", processor.process("テスト")[1])
            end
        end)
    end)

    describe("translator", function()
        local dict, translator

        setup(function()
            dict = assert(Dictionary.open(fixtures .. "test_dictionary"))
            translator = Translator.new{ dictionaries = { dict }, json_decode = require("rapidjson").decode }
        end)

        teardown(function()
            dict:close()
        end)

        local function summarize(entry)
            local headwords = {}
            for i, hw in ipairs(entry.headwords) do
                local tags, sources = {}, {}
                for j, tag in ipairs(hw.tags) do tags[j] = tag.name end
                for j, s in ipairs(hw.sources) do
                    sources[j] = table.concat({s.original_text, s.transformed_text, s.deinflected_text, s.match_source, tostring(s.is_primary)}, "|")
                end
                headwords[i] = { hw.term, hw.reading, tags = tags, sources = sources }
            end
            local chains = {}
            for i, chain in ipairs(entry.inflection_rule_chain_candidates) do
                local names = {}
                for j, rule in ipairs(chain.inflection_rules) do names[j] = rule.name end
                chains[i] = chain.source .. ":" .. table.concat(names, ",")
            end
            local definitions = {}
            for i, d in ipairs(entry.definitions) do
                local tags = {}
                for _, tag in ipairs(d.tags) do
                    if not tag.redundant then table.insert(tags, tag.name) end
                end
                -- Ids are dictionary order * 2^32 + row id; the row id is Yomitan's id.
                definitions[i] = { id = d.id % 4294967296, headword_indices = d.headword_indices, tags = tags }
            end
            return {
                score = entry.score,
                max_original_text_length = entry.max_original_text_length,
                source_term_exact_match_count = entry.source_term_exact_match_count,
                headwords = headwords,
                chains = chains,
                definitions = definitions,
            }
        end

        it("matches Yomitan's translator test results", function()
            for _, case in ipairs(dofile(fixtures .. "translator_cases.lua")) do
                local result = translator:findTerms(case.text, { mode = case.mode, remove_non_japanese = case.remove_non_japanese })
                local actual = {}
                for i, entry in ipairs(result.entries) do actual[i] = summarize(entry) end
                assert.are.same(case.entries, actual, case.name)
            end
        end)

        it("reports the length of the longest match", function()
            local result = translator:findTerms("打ち込んでいませんでした。それから", {})
            assert.are.equal(12, result.original_text_length)
            assert.are.equal("打ち込む", result.entries[1].headwords[1].term)
            result = translator:findTerms("ありません", {})
            assert.are.equal(0, result.original_text_length)
            assert.are.same({}, result.entries)
        end)
    end)

    describe("html", function()
        it("renders structured content like Yomitan", function()
            local html = Html.structuredContent({
                { tag = "span", data = { content = "tag", fooBar = "x" }, style = { fontWeight = "bold", marginTop = 0.5 }, content = "名" },
                { tag = "ruby", content = { "漢字", { tag = "rt", content = "かんじ" } } },
                { tag = "ruby", content = { "字", { tag = "rp", content = "(" }, { tag = "rt", content = "じ" }, { tag = "rp", content = ")" } } },
                { tag = "a", href = "?query=%E9%A3%9F%E3%81%B9%E3%82%8B&wildcards=off", content = "食べる" },
                { tag = "br" },
                { tag = "table", content = { tag = "tr", content = { tag = "td", colSpan = 2, content = "<x>" } } },
            })
            assert.are.equal(table.concat({
                '<span class="gloss-sc-span" data-sc-content="tag" data-sc-foo-bar="x" style="font-weight:bold;margin-top:0.5em">名</span>',
                '<span class="gloss-sc-ruby">漢字<span class="gloss-sc-rt">(かんじ)</span></span>',
                '<span class="gloss-sc-ruby">字<span class="gloss-sc-rp">(</span><span class="gloss-sc-rt">じ</span><span class="gloss-sc-rp">)</span></span>',
                '<a class="gloss-link" href="bword://食べる"><span class="gloss-link-text">食べる</span></a>',
                '<br/>',
                '<div class="gloss-sc-table-container"><table class="gloss-sc-table"><tr class="gloss-sc-tr"><td class="gloss-sc-td" colspan="2">&lt;x&gt;</td></tr></table></div>',
            }), html)
        end)

        it("sizes images like Yomitan", function()
            -- 350 "px" preferred width at Yomitan's 14px image font size, capped.
            local html = Html.image({ path = "a b.png", width = 7, height = 7, preferredWidth = 140, preferredHeight = 70 }) -- unscaled_size_check: ignore
            assert.are.equal('<span class="gloss-image-link"><img src="media/a b.png" class="gloss-image" style="width:10.000em;height:5.000em"/></span>', html)
            html = Html.image({ path = "c.png", width = 10, height = 20, preferredWidth = 2, sizeUnits = "em" }) -- unscaled_size_check: ignore
            assert.is_truthy(html:find("width:2.000em;height:4.000em", 1, true))
        end)
    end)

    describe("scanner", function()
        -- A document "漢字(かんじ)を読む" where かんじ is ruby text: positions
        -- are fake XPointers; the furigana lives in an <rt> element.
        local positions = {
            { "/body/p/ruby/text().0", "漢" },
            { "/body/p/ruby/text().1", "字" },
            { "/body/p/ruby/rt/text().0", "か" },
            { "/body/p/ruby/rt/text().1", "ん" },
            { "/body/p/ruby/rt/text().2", "じ" },
            { "/body/p/text().0", "を" },
            { "/body/p/text().1", "読" },
            { "/body/p/text().2", "む" },
            { "/body/p/text().3", nil },
        }
        local index_of = {}
        for i, p in ipairs(positions) do index_of[p[1]] = i end
        local callbacks = {
            get_next_char_pos = function(xp)
                local i = index_of[xp]
                return positions[i + 1] and positions[i + 1][1]
            end,
            get_text_in_range = function(xp0, xp1)
                local out = {}
                for i = index_of[xp0], index_of[xp1] - 1 do table.insert(out, positions[i][2]) end
                return table.concat(out)
            end,
        }

        it("skips ruby annotations", function()
            local text, ends = Scanner.scan(callbacks, positions[1][1], 16)
            assert.are.equal("漢字を読む", text)
            assert.are.equal(positions[2][1], ends[1])
            -- The range ends before the furigana of 字.
            assert.are.equal(positions[3][1], ends[2])
            assert.are.equal(positions[9][1], ends[5])
        end)

        it("honours the scan length", function()
            local text = Scanner.scan(callbacks, positions[1][1], 3)
            assert.are.equal("漢字を", text)
        end)

        it("scans furigana when it is tapped directly", function()
            local text = Scanner.scan(callbacks, positions[3][1], 3)
            assert.are.equal("かんじ", text)
        end)
    end)
end)
