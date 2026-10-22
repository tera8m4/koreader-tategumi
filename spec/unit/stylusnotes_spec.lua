-- Specs for plugins/stylusnotes.koplugin: stroke anchoring (pure math), the
-- note codec, and ink following the text across a reflow in crengine.
describe("Stylus notes", function()
    local Anchor, NoteCanvas

    setup(function()
        require("commonrequire")
        package.path = "plugins/stylusnotes.koplugin/?.lua;" .. package.path
        Anchor = require("stylusnotes/anchor")
        NoteCanvas = require("stylusnotes/canvas")
    end)

    describe("anchor math", function()
        local function originAt(gx, gy)
            -- Screen origin for doc (block, inline), relative to a glyph at doc (10, 100)
            return function(block, inline)
                return gx + (inline - 100), gy + (block - 10)
            end
        end

        local metrics = {
            inline0 = 100, inline1 = 120, block0 = 10, block1 = 40,
            block_start = 50, block_end = 500, font_size = 20, vertical = false,
        }

        it("round-trips the codec", function()
            local pts = { 0, 0, 64, 10, -5, 64, -300, 1200, 80 }
            assert.are.same(pts, Anchor.decode(Anchor.encode(pts)))
        end)

        it("places a stroke back where it was drawn", function()
            local origin = originAt(300, 200)
            local stroke = { xy = { 300, 210, 340, 215, 360, 205 }, r = { 2, 3, 2 } }
            local a = Anchor.capture(stroke, metrics, origin)
            assert.are.equal("glyph", a.ref)
            local xy, radii = Anchor.place(a, metrics, origin)
            assert.are.same(stroke.xy, xy)
            assert.are.same({ 2, 3, 2 }, radii)
        end)

        it("scales with the font size", function()
            local origin = originAt(300, 200)
            local a = Anchor.capture({ xy = { 300, 200, 340, 200 }, r = { 2, 2 } }, metrics, origin)
            local bigger = {}
            for k, v in pairs(metrics) do bigger[k] = v end
            bigger.font_size = 40
            local xy = Anchor.place(a, bigger, origin)
            assert.are.same({ 300, 200, 380, 200 }, xy)
        end)

        it("keeps margin strokes beside the paragraph edge", function()
            local origin = originAt(300, 200)
            -- inline 30..40 is before block_start (50): a start-margin stroke
            local a = Anchor.capture({ xy = { 230, 210, 240, 220 }, r = { 2, 2 } }, metrics, origin)
            assert.are.equal("start", a.ref)
            local moved = {}
            for k, v in pairs(metrics) do moved[k] = v end
            moved.inline0 = 300 -- the anchor glyph moved along the line
            local xy = Anchor.place(a, moved, function(block, inline)
                return 300 + (inline - 100), 200 + (block - 10)
            end)
            assert.are.same({ 230, 210, 240, 220 }, xy)
        end)

        it("rotates logical offsets for vertical-rl", function()
            local di, db = Anchor.toLogical(-6, 9, true)
            assert.are.equal(9, di)
            assert.are.equal(6, db)
            assert.are.same({ -6, 9 }, { Anchor.toScreen(di, db, true) })
        end)

        it("hit-tests polylines", function()
            local xy = { 0, 0, 100, 0 }
            assert.is_true(Anchor.hits(xy, 50, 4, 5))
            assert.is_false(Anchor.hits(xy, 50, 6, 5))
            assert.is_false(Anchor.hits(xy, 110, 0, 5))
        end)
    end)

    it("round-trips handwritten notes across sheet widths", function()
        local strokes = { { xy = { 10, 20, 30, 40 }, r = { 2, 4 } } }
        local note = NoteCanvas.encodeNote(strokes, 1000, 1500)
        assert.are.same(strokes, NoteCanvas.decodeNote(note, 1000))
        local half = NoteCanvas.decodeNote(note, 500)
        assert.are.same({ 5, 10, 15, 20 }, half[1].xy)
    end)

    describe("ink following the text", function()
        local DocumentRegistry, ReaderUI, Screen, UIManager

        setup(function()
            disable_plugins()
            require("document/canvascontext"):init(require("device"))
            DocumentRegistry = require("document/documentregistry")
            ReaderUI = require("apps/reader/readerui")
            Screen = require("device").screen
            UIManager = require("ui/uimanager")
        end)

        local function check(epub_path, vertical)
            local f = io.open(epub_path, "r")
            if not f then pending("no " .. epub_path) return end
            f:close()
            local readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(epub_path),
            }
            UIManager:show(readerui)
            if vertical and readerui.styletweak then
                readerui.styletweak.book_style_tweak = "body { writing-mode: vertical-rl !important; }"
                readerui.styletweak.book_style_tweak_enabled = true
                readerui.styletweak:updateCssText(true)
            end
            fastforward_ui_events()
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()

            local doc = readerui.document
            local origin = function(block, inline) return doc:docToScreenPoint(block, inline) end
            local cx, cy = math.floor(Screen:getWidth() / 2), math.floor(Screen:getHeight() / 2)
            local xp = doc:getXPointerFromScreenPoint(cx, cy)
            assert.is_truthy(xp)
            local m = doc:getXPointerLineMetrics(xp)
            assert.is_truthy(m)
            assert.are.equal(vertical, m.vertical)
            assert.is_true(m.font_size > 0)

            -- A short underline-like stroke at the anchor glyph's line
            local gx, gy = origin(m.block0, m.inline0)
            local dx, dy = Anchor.toScreen(m.font_size, m.block1 - m.block0, vertical)
            local stroke = { xy = { gx, gy, gx + dx, gy + dy }, r = { 2, 2 } }
            local anchored = Anchor.capture(stroke, m, origin)
            assert.are.same(stroke.xy, (Anchor.place(anchored, m, origin)))

            -- Reflow, and go to the anchor again
            readerui.font:onSetFontSize(m.font_size + 8)
            fastforward_ui_events()
            readerui.rolling:onGotoXPointer(xp)
            fastforward_ui_events()
            local m2 = doc:getXPointerLineMetrics(xp)
            assert.is_true(m2.font_size > m.font_size)
            local xy = Anchor.place(anchored, m2, origin)
            assert.is_truthy(xy)
            local g2x, g2y = origin(m2.block0, m2.inline0)
            -- Starts at the anchor glyph and spans one (new) em along the line
            assert.are.same({ g2x, g2y }, { xy[1], xy[2] })
            local inline_len = vertical and (xy[4] - xy[2]) or (xy[3] - xy[1])
            assert.is_true(math.abs(inline_len - m2.font_size) <= 1)

            readerui:onClose()
            UIManager:quit()
        end

        it("in horizontal text", function()
            check("spec/front/unit/data/juliet.epub", false)
        end)

        it("in vertical text", function()
            check("spec/front/unit/data/fixtures/vertical_text/simple_ja_noruby.epub", true)
        end)
    end)
end)
