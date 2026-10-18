--[[--
Vertical text: keep Japanese words together at column breaks.

Paragraphs put 飛び降りる at every offset from the column start, so that column
breaks fall at every position inside it. Without keep-words (MIN = 0) some
column splits it badly (飛び降|りる, cost 8 or more); with MIN = 2 none does.
With shrinkable punctuation spacing in the column, the rest of the word is
squeezed in instead of being split.

See doc/Japanese_line_breaking.md. Run via:
  ./kodev test front -f "keep words"
--]]

describe("Vertical text: keep words together #keep_words", function()
    local DocumentRegistry, DocSettings, ReaderUI, Screen, UIManager
    local cre
    local html_path = "/tmp/koreader_vertical_keep_words.xhtml"
    local WORD = "飛び降りる"
    local WORD_LENGTH = 5
    local OFFSETS = 50 -- more than the chars in a column

    setup(function()
        require("commonrequire")
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        DocumentRegistry = require("document/documentregistry")
        DocSettings      = require("docsettings")
        ReaderUI         = require("apps/reader/readerui")
        Screen           = require("device").screen
        UIManager        = require("ui/uimanager")
        cre = require("document/credocument"):engineInit()
        cre.jpSetDeinflectRules(dofile("plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua"))
        assert.is.truthy(cre.jpSetWords("spec/front/unit/yomitan/jpwords.tsv"))
        cre.jpSetKeepIdioms(false)
    end)

    teardown(function()
        cre.jpSetMinKeep(0)
        cre.jpSetWords("")
        os.remove(html_path)
    end)

    -- 犬 is a word of its own, so a break between two 犬 costs nothing.
    -- `filler` repeats before the word; "犬、" gives the column spacing that
    -- justification can shrink.
    local function write_fixture(filler)
        local paragraphs = {}
        for offset = 0, OFFSETS - 1 do
            table.insert(paragraphs, "<p>" .. string.rep(filler, offset) .. WORD
                .. string.rep("犬", 3 * OFFSETS) .. "</p>")
        end
        local f = assert(io.open(html_path, "wb"))
        f:write([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="UTF-8"/><title>keep words</title>
<style>
html, body { margin: 0; padding: 0; }
body { writing-mode: vertical-rl; font-family: serif; }
p { margin: 0; text-indent: 0; text-align: justify; }
</style></head>
<body>]] .. table.concat(paragraphs) .. "</body></html>")
        f:close()
    end

    -- For each occurrence of the word: the number of its chars before the
    -- first column break inside it (0 when it is not split).
    local function split_positions(filler, min_keep)
        cre.jpSetMinKeep(min_keep)
        write_fixture(filler)
        local reader = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(html_path),
        }
        UIManager:show(reader)
        reader.document:setFontSize(30)
        fastforward_ui_events()
        local doc = reader.document
        local hits = doc:findAllText(WORD, false, 0, 1000, false)
        assert.are.equal(OFFSETS, hits and #hits)
        local splits = {}
        for _, hit in ipairs(hits) do
            reader.rolling:onGotoXPointer(hit.start)
            fastforward_ui_events()
            local xp = hit.start
            local _, first_x = doc:getScreenPositionFromXPointer(xp)
            local split = 0
            for i = 1, WORD_LENGTH - 1 do
                xp = doc:getNextVisibleChar(xp)
                local _, x = doc:getScreenPositionFromXPointer(xp)
                if x ~= first_x then
                    split = i
                    break
                end
            end
            -- Also note a break right after the word.
            if split == 0 then
                xp = doc:getNextVisibleChar(xp)
                local _, x = doc:getScreenPositionFromXPointer(xp)
                if x ~= first_x then split = WORD_LENGTH end
            end
            table.insert(splits, split)
        end
        reader:onClose()
        UIManager:quit()
        UIManager._exit_code = nil
        DocSettings:open(html_path):purge()
        return splits
    end

    -- 飛|び, 飛び降|りる and 飛び降り|る: fewer than 2 letters on a side, or okurigana.
    local function bad_splits(splits)
        local n = 0
        for _, split in ipairs(splits) do
            if split == 1 or split == 3 or split == 4 then n = n + 1 end
        end
        return n
    end

    local function count(splits, value)
        local n = 0
        for _, split in ipairs(splits) do
            if split == value then n = n + 1 end
        end
        return n
    end

    it("splits words anywhere when off", function()
        local splits = split_positions("犬", 0)
        print("[keep_words] off:", table.concat(splits, ","))
        assert.is_true(bad_splits(splits) > 0)
    end)

    it("leaves no bad split with MIN = 2", function()
        local splits = split_positions("犬", 2)
        print("[keep_words] min 2:", table.concat(splits, ","))
        assert.are.equal(0, bad_splits(splits))
    end)

    it("squeezes the rest of the word in when spacing can shrink", function()
        local off = split_positions("犬、", 0)
        local on = split_positions("犬、", 2)
        print("[keep_words] squeeze off:", table.concat(off, ","))
        print("[keep_words] squeeze min 2:", table.concat(on, ","))
        assert.are.equal(0, bad_splits(on))
        -- Breaks right after the word: squeezing in ends more columns there.
        assert.is_true(count(on, WORD_LENGTH) > count(off, WORD_LENGTH))
    end)
end)
