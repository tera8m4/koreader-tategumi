--[[--
Japanese text utilities and text preprocessors, ported from Yomitan
(ext/js/language/ja/japanese.js, japanese-wanakana.js,
japanese-text-preprocessors.js and ext/js/language/CJK-util.js).

@module yomitan.japanese
]]

local UString = require("yomitan/ustring")
local TextData = require("yomitan/data/text_ja")

local chars, codepoint, uchar = UString.chars, UString.codepoint, UString.char
local inRanges = UString.inRanges

local Japanese = {}

-- Code point ranges (CJK-util.js / japanese.js).
local CJK_IDEOGRAPH_RANGES = {
    {0x4e00, 0x9fff}, {0x3400, 0x4dbf}, {0x20000, 0x2a6df}, {0x2a700, 0x2b73f},
    {0x2b740, 0x2b81f}, {0x2b820, 0x2ceaf}, {0x2ceb0, 0x2ebef}, {0x30000, 0x3134f},
    {0x31350, 0x323af}, {0x2ebf0, 0x2ee5f}, {0xf900, 0xfaff}, {0x2f800, 0x2fa1f},
}
local FULLWIDTH_CHARACTER_RANGES = {
    {0xff10, 0xff19}, {0xff21, 0xff3a}, {0xff41, 0xff5a},
    {0xff01, 0xff0f}, {0xff1a, 0xff1f}, {0xff3b, 0xff3f}, {0xff5b, 0xff60}, {0xffe0, 0xffee},
}
local CJK_PUNCTUATION_RANGE = {0x3000, 0x303f}
local HIRAGANA_RANGE = {0x3040, 0x309f}
local KATAKANA_RANGE = {0x30a0, 0x30ff}

local function concatRanges(...)
    local out = {}
    for _, list in ipairs({...}) do
        for _, r in ipairs(list) do table.insert(out, r) end
    end
    return out
end

local KANA_RANGES = {HIRAGANA_RANGE, KATAKANA_RANGE}
local JAPANESE_RANGES = concatRanges(
    KANA_RANGES, CJK_IDEOGRAPH_RANGES,
    {{0xff66, 0xff9f}, {0x30fb, 0x30fc}, {0xff61, 0xff65}, CJK_PUNCTUATION_RANGE},
    FULLWIDTH_CHARACTER_RANGES)
-- Used by Yomitan's removeNonJapaneseCharacters, which keeps Japanese,
-- Chinese and Korean characters (zh/chinese.js, ko/korean.js).
local CJK_LANGUAGE_RANGES = concatRanges(
    JAPANESE_RANGES,
    {{0x3100, 0x312f}, {0x31a0, 0x31bf}, {0x16fe0, 0x16fff}, {0xfe50, 0xfe6f}, {0xfe10, 0xfe1f}},
    {{0x1100, 0x11ff}, {0x3130, 0x318f}, {0xac00, 0xd7af}, {0xa960, 0xa97f}, {0xd7b0, 0xd7ff}, {0xffa0, 0xffdf}})

function Japanese.isCodePointKanji(cp) return inRanges(cp, CJK_IDEOGRAPH_RANGES) end
function Japanese.isCodePointKana(cp) return inRanges(cp, KANA_RANGES) end
function Japanese.isCodePointJapanese(cp) return inRanges(cp, JAPANESE_RANGES) end

--- Whether any character of str is Japanese (isStringPartiallyJapanese).
function Japanese.isStringPartiallyJapanese(str)
    for _, c in ipairs(chars(str)) do
        if inRanges(codepoint(c), JAPANESE_RANGES) then return true end
    end
    return false
end

--- Truncate text at the first character which is not Japanese, Chinese or
-- Korean (translator.js _getJapaneseChineseKoreanOnlyText).
function Japanese.getCJKOnlyText(text)
    local out = {}
    for i, c in ipairs(chars(text)) do
        if not inRanges(codepoint(c), CJK_LANGUAGE_RANGES) then break end
        out[i] = c
    end
    return table.concat(out)
end

-- Kana conversions

local HIRAGANA_CONVERSION_MIN, HIRAGANA_CONVERSION_MAX = 0x3041, 0x3096
local KATAKANA_CONVERSION_MIN, KATAKANA_CONVERSION_MAX = 0x30a1, 0x30f6
local KATAKANA_SMALL_KA, KATAKANA_SMALL_KE = 0x30f5, 0x30f6
local PROLONGED_SOUND_MARK = 0x30fc

local KANA_TO_VOWEL = {}
for vowel, list in pairs({
    a = "ぁあかがさざただなはばぱまゃやらゎわヵァアカガサザタダナハバパマャヤラヮワヵヷ",
    i = "ぃいきぎしじちぢにひびぴみりゐィイキギシジチヂニヒビピミリヰヸ",
    u = "ぅうくぐすずっつづぬふぶぷむゅゆるゥウクグスズッツヅヌフブプムュユルヴ",
    e = "ぇえけげせぜてでねへべぺめれゑヶェエケゲセゼテデネヘベペメレヱヶヹ",
    o = "ぉおこごそぞとどのほぼぽもょよろをォオコゴソゾトドノホボポモョヨロヲヺ",
}) do
    for _, c in ipairs(chars(list)) do KANA_TO_VOWEL[c] = vowel end
end
-- In Yomitan the '' vowel entry for の/ノ is inserted last and wins.
KANA_TO_VOWEL["の"] = ""
KANA_TO_VOWEL["ノ"] = ""
local PROLONGED_HIRAGANA = { a = "あ", i = "い", u = "う", e = "え", o = "う" }

function Japanese.convertKatakanaToHiragana(text, keep_prolonged_sound_marks)
    local result = {}
    local offset = HIRAGANA_CONVERSION_MIN - KATAKANA_CONVERSION_MIN
    for _, c in ipairs(chars(text)) do
        local cp = codepoint(c)
        if cp == KATAKANA_SMALL_KA or cp == KATAKANA_SMALL_KE then -- luacheck: ignore 542
            -- No change
        elseif cp == PROLONGED_SOUND_MARK then
            if not keep_prolonged_sound_marks and #result > 0 then
                local c2 = PROLONGED_HIRAGANA[KANA_TO_VOWEL[result[#result]]]
                if c2 then c = c2 end
            end
        elseif cp >= KATAKANA_CONVERSION_MIN and cp <= KATAKANA_CONVERSION_MAX then
            c = uchar(cp + offset)
        end
        result[#result + 1] = c
    end
    return table.concat(result)
end

function Japanese.convertHiraganaToKatakana(text)
    local result = {}
    local offset = KATAKANA_CONVERSION_MIN - HIRAGANA_CONVERSION_MIN
    for i, c in ipairs(chars(text)) do
        local cp = codepoint(c)
        if cp >= HIRAGANA_CONVERSION_MIN and cp <= HIRAGANA_CONVERSION_MAX then
            c = uchar(cp + offset)
        end
        result[i] = c
    end
    return table.concat(result)
end

function Japanese.convertAlphanumericToFullWidth(text)
    local result = {}
    for i, c in ipairs(chars(text)) do
        local cp = codepoint(c)
        if cp >= 0x30 and cp <= 0x39 then
            c = uchar(cp + 0xff10 - 0x30)
        elseif cp >= 0x41 and cp <= 0x5a then
            c = uchar(cp + 0xff21 - 0x41)
        elseif cp >= 0x61 and cp <= 0x7a then
            c = uchar(cp + 0xff41 - 0x61)
        end
        result[i] = c
    end
    return table.concat(result)
end

function Japanese.convertFullWidthAlphanumericToNormal(text)
    local result = {}
    for i, c in ipairs(chars(text)) do
        local cp = codepoint(c)
        if cp >= 0xff10 and cp <= 0xff19 then
            c = uchar(cp - (0xff10 - 0x30))
        elseif cp >= 0xff21 and cp <= 0xff3a then
            c = uchar(cp - (0xff21 - 0x41))
        elseif cp >= 0xff41 and cp <= 0xff5a then
            c = uchar(cp - (0xff41 - 0x61))
        end
        result[i] = c
    end
    return table.concat(result)
end

-- Halfwidth katakana: base, dakuten and handakuten forms ("-" means invalid).
local HALFWIDTH_KATAKANA_MAPPING = {}
for _, entry in ipairs({
    {"･", "・--"}, {"ｦ", "ヲヺ-"}, {"ｧ", "ァ--"}, {"ｨ", "ィ--"}, {"ｩ", "ゥ--"}, {"ｪ", "ェ--"},
    {"ｫ", "ォ--"}, {"ｬ", "ャ--"}, {"ｭ", "ュ--"}, {"ｮ", "ョ--"}, {"ｯ", "ッ--"}, {"ｰ", "ー--"},
    {"ｱ", "ア--"}, {"ｲ", "イ--"}, {"ｳ", "ウヴ-"}, {"ｴ", "エ--"}, {"ｵ", "オ--"}, {"ｶ", "カガ-"},
    {"ｷ", "キギ-"}, {"ｸ", "クグ-"}, {"ｹ", "ケゲ-"}, {"ｺ", "コゴ-"}, {"ｻ", "サザ-"}, {"ｼ", "シジ-"},
    {"ｽ", "スズ-"}, {"ｾ", "セゼ-"}, {"ｿ", "ソゾ-"}, {"ﾀ", "タダ-"}, {"ﾁ", "チヂ-"}, {"ﾂ", "ツヅ-"},
    {"ﾃ", "テデ-"}, {"ﾄ", "トド-"}, {"ﾅ", "ナ--"}, {"ﾆ", "ニ--"}, {"ﾇ", "ヌ--"}, {"ﾈ", "ネ--"},
    {"ﾉ", "ノ--"}, {"ﾊ", "ハバパ"}, {"ﾋ", "ヒビピ"}, {"ﾌ", "フブプ"}, {"ﾍ", "ヘベペ"}, {"ﾎ", "ホボポ"},
    {"ﾏ", "マ--"}, {"ﾐ", "ミ--"}, {"ﾑ", "ム--"}, {"ﾒ", "メ--"}, {"ﾓ", "モ--"}, {"ﾔ", "ヤ--"},
    {"ﾕ", "ユ--"}, {"ﾖ", "ヨ--"}, {"ﾗ", "ラ--"}, {"ﾘ", "リ--"}, {"ﾙ", "ル--"}, {"ﾚ", "レ--"},
    {"ﾛ", "ロ--"}, {"ﾜ", "ワ--"}, {"ﾝ", "ン--"},
}) do
    HALFWIDTH_KATAKANA_MAPPING[entry[1]] = chars(entry[2])
end

function Japanese.convertHalfWidthKanaToFullWidth(text)
    local result = {}
    local cs = chars(text)
    local i = 1
    while i <= #cs do
        local c = cs[i]
        local mapping = HALFWIDTH_KATAKANA_MAPPING[c]
        if not mapping then
            result[#result + 1] = c
        else
            local index = 1
            local next_cp = cs[i + 1] and codepoint(cs[i + 1])
            if next_cp == 0xff9e then -- dakuten
                index = 2
            elseif next_cp == 0xff9f then -- handakuten
                index = 3
            end
            local c2 = mapping[index]
            if index > 1 then
                if c2 == "-" then
                    c2 = mapping[1]
                else
                    i = i + 1
                end
            end
            result[#result + 1] = c2
        end
        i = i + 1
    end
    return table.concat(result)
end

local function dakutenAllowed(cp)
    return (cp >= 0x304B and cp <= 0x3068) or (cp >= 0x306F and cp <= 0x307B)
        or (cp >= 0x30AB and cp <= 0x30C8) or (cp >= 0x30CF and cp <= 0x30DB)
end

local function handakutenAllowed(cp)
    return (cp >= 0x306F and cp <= 0x307B) or (cp >= 0x30CF and cp <= 0x30DB)
end

function Japanese.normalizeCombiningCharacters(text)
    local cs = chars(text)
    local result = {}
    local i = #cs
    -- Ignoring the first character is intentional, it cannot combine with anything.
    while i > 1 do
        local c = cs[i]
        local combined
        if c == "\227\130\153" then -- U+3099 combining dakuten
            local cp = codepoint(cs[i - 1])
            if dakutenAllowed(cp) then combined = uchar(cp + 1) end
        elseif c == "\227\130\154" then -- U+309A combining handakuten
            local cp = codepoint(cs[i - 1])
            if handakutenAllowed(cp) then combined = uchar(cp + 2) end
        end
        if combined then
            table.insert(result, 1, combined)
            i = i - 2
        else
            table.insert(result, 1, c)
            i = i - 1
        end
    end
    if i == 1 then
        table.insert(result, 1, cs[1])
    end
    return table.concat(result)
end

local function mapChars(text, map)
    local cs = chars(text)
    for i, c in ipairs(cs) do
        local m = map[c]
        if m then cs[i] = m end
    end
    return table.concat(cs)
end

function Japanese.normalizeCJKCompatibilityCharacters(text)
    return mapChars(text, TextData.cjk_compatibility_nfkd)
end

function Japanese.normalizeRadicals(text)
    return mapChars(text, TextData.radicals_nfkd)
end

function Japanese.convertKanjiVariants(text)
    return mapChars(text, TextData.kanji_variants)
end

-- Emphatic sequences

local EMPHATIC = { ["っ"] = true, ["ッ"] = true, ["ー"] = true }

function Japanese.collapseEmphaticSequences(text, full_collapse)
    local cs = chars(text)
    local left = 1
    while left <= #cs and EMPHATIC[cs[left]] do left = left + 1 end
    local right = #cs
    while right >= 1 and EMPHATIC[cs[right]] do right = right - 1 end
    if left > right then
        return text -- whole string is emphatic
    end
    local out = {}
    for i = 1, left - 1 do out[#out + 1] = cs[i] end
    local current = nil
    for i = left, right do
        local c = cs[i]
        if EMPHATIC[c] then
            if current ~= c then
                current = c
                if not full_collapse then
                    out[#out + 1] = c
                end
            end
        else
            current = nil
            out[#out + 1] = c
        end
    end
    for i = right + 1, #cs do out[#out + 1] = cs[i] end
    return table.concat(out)
end

-- Romaji (japanese-wanakana.js)

local function fillSokuonGaps(text)
    -- text.replaceAll(/っ[a-z](?=っ)/g, 'っっ').replaceAll(/ッ[A-Z](?=ッ)/g, 'ッッ')
    local function fill(s, sokuon, lo, hi)
        local cs = chars(s)
        local out = {}
        local i = 1
        while i <= #cs do
            local c = cs[i]
            local n = cs[i + 1]
            if c == sokuon and n and #n == 1 and n:byte() >= lo and n:byte() <= hi and cs[i + 2] == sokuon then
                out[#out + 1] = sokuon
                out[#out + 1] = sokuon
                i = i + 2
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return table.concat(out)
    end
    text = fill(text, "っ", 0x61, 0x7a)
    return fill(text, "ッ", 0x41, 0x5a)
end

local function convertToHiragana(text)
    local new_text = text:lower()
    for _, pair in ipairs(TextData.romaji_to_hiragana) do
        new_text = UString.replaceAll(new_text, pair[1], pair[2])
    end
    return fillSokuonGaps(new_text)
end

function Japanese.convertAlphabeticToKana(text)
    local part = {}
    local result = {}
    local function flush()
        if #part > 0 then
            result[#result + 1] = convertToHiragana(table.concat(part))
            part = {}
        end
    end
    for _, c in ipairs(chars(text)) do
        local cp = codepoint(c)
        if cp >= 0x41 and cp <= 0x5a then
            cp = cp + (0x61 - 0x41)
        elseif cp >= 0x61 and cp <= 0x7a then -- luacheck: ignore 542
            -- NOP
        elseif cp >= 0xff21 and cp <= 0xff3a then
            cp = cp + (0x61 - 0xff21)
        elseif cp >= 0xff41 and cp <= 0xff5a then
            cp = cp + (0x61 - 0xff41)
        elseif cp == 0x2d or cp == 0xff0d then
            cp = 0x2d
        else
            cp = nil
        end
        if cp then
            part[#part + 1] = string.char(cp)
        else
            flush()
            result[#result + 1] = c
        end
    end
    flush()
    return table.concat(result)
end

--- The Japanese text preprocessors, in Yomitan's order
-- (language-descriptors.js). Each process function returns the variants,
-- the first of which is always the unchanged input.
Japanese.TEXT_PREPROCESSORS = {
    {
        id = "convertHalfWidthCharacters",
        name = "Convert half width characters to full width",
        process = function(s) return {s, Japanese.convertHalfWidthKanaToFullWidth(s)} end,
    },
    {
        id = "alphabeticToHiragana",
        name = "Convert alphabetic characters to hiragana",
        process = function(s) return {s, Japanese.convertAlphabeticToKana(s)} end,
    },
    {
        id = "normalizeCombiningCharacters",
        name = "Normalize combining characters",
        process = function(s) return {s, Japanese.normalizeCombiningCharacters(s)} end,
    },
    {
        id = "normalizeCJKCompatibilityCharacters",
        name = "Normalize CJK Compatibility Characters",
        process = function(s) return {s, Japanese.normalizeCJKCompatibilityCharacters(s)} end,
    },
    {
        id = "normalizeRadicalCharacters",
        name = "Normalize radical characters",
        process = function(s) return {s, Japanese.normalizeRadicals(s)} end,
    },
    {
        id = "alphanumericWidthVariants",
        name = "Convert between alphabetic width variants",
        process = function(s)
            return {s, Japanese.convertFullWidthAlphanumericToNormal(s), Japanese.convertAlphanumericToFullWidth(s)}
        end,
    },
    {
        id = "convertHiraganaToKatakana",
        name = "Convert hiragana to katakana",
        process = function(s)
            return {s, Japanese.convertHiraganaToKatakana(s), Japanese.convertKatakanaToHiragana(s)}
        end,
    },
    {
        id = "collapseEmphaticSequences",
        name = "Collapse emphatic character sequences",
        process = function(s)
            return {s, Japanese.collapseEmphaticSequences(s, false), Japanese.collapseEmphaticSequences(s, true)}
        end,
    },
    {
        id = "standardizeKanji",
        name = "Convert kanji variants to their modern standard form",
        process = function(s) return {s, Japanese.convertKanjiVariants(s)} end,
    },
}

return Japanese
