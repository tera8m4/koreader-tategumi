--[[--
ReaderView module marking the recorded words on the current page.

The page's characters are read with crengine (ruby text skipped), matched
with bookwords/matcher.lua, and the screen boxes of the matches are cached
per page. Matching runs right after the page is shown, so page turns are not
delayed; the marks then appear with a refresh of their area only.

Marks are a thin line beside each column (vertical text) or under each line
(horizontal text). Optionally, the reading is drawn beside words containing
kanji that have no ruby in the book.

@module bookwords.marker
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Matcher = require("bookwords/matcher")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local Screen = Device.screen

local MAX_STEPS = 6000 -- characters walked per page, at most

local Marker = {}
Marker.__index = Marker

function Marker.new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui, marks = {}, furigana = {} }, Marker)
end

local function isRubyAnnotation(xp)
    return xp:find("/r[tp]%f[^%w]") ~= nil
end

local function hasKanji(s)
    for c in s:gmatch(util.UTF8_CHAR_PATTERN) do
        if #c == 3 then
            local cp = (c:byte(1) % 16) * 4096 + (c:byte(2) % 64) * 64 + c:byte(3) % 64
            if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or cp == 0x3005 then
                return true
            end
        elseif #c == 4 then
            return true -- CJK extension planes
        end
    end
    return false
end

function Marker:_cacheKey()
    local doc = self.ui.document
    local settings = self.plugin.settings
    return table.concat({
        doc:getCurrentPage(),
        doc:getDocumentRenderingHash(),
        self.plugin.store.version,
        settings.furigana and 1 or 0,
    }, ":")
end

function Marker:isActive()
    return self.plugin.settings.mark and self.plugin.store and not self.plugin.store:isEmpty()
        and self.ui.view and self.ui.view.view_mode == "page"
end

function Marker:invalidate()
    self.cache_key = nil
end

function Marker:paintTo(bb, x, y)
    if not self:isActive() then return end
    if self:_cacheKey() ~= self.cache_key then
        self:_schedule()
        return
    end
    for _, mark in ipairs(self.marks) do
        bb:paintRect(x + mark.x, y + mark.y, mark.w, mark.h, Blitbuffer.COLOR_DARK_GRAY)
    end
    for _, f in ipairs(self.furigana) do
        f.widget:paintTo(bb, x + f.x, y + f.y)
    end
end

function Marker:_schedule()
    if self.scheduled then return end
    self.scheduled = true
    UIManager:nextTick(function()
        self.scheduled = false
        if not self:isActive() then return end
        local ok, err = pcall(self._compute, self)
        if not ok then
            logger.warn("bookwords: marking failed", err)
            self.cache_key = self:_cacheKey() -- don't retry on every repaint
            return
        end
        if self.region then
            -- Not "fast": its black-and-white waveform drops the gray
            -- lines and the antialiasing of the furigana.
            UIManager:setDirty(self.ui.dialog, "ui", self.region)
        end
    end)
end

--- The current page's characters: {char,...} and {{xp0, xp1, ruby},...}.
function Marker:_readPage()
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local xp = doc:getPageXPointer(page)
    local end_xp = doc:getPageXPointer(page + doc:getVisiblePageCount())
    local chars, info = {}, {}
    local steps = 0
    while xp and steps < MAX_STEPS do
        steps = steps + 1
        if end_xp and doc:compareXPointers(xp, end_xp) ~= 1 then break end
        local next_xp = doc:getNextVisibleChar(xp)
        if not next_xp or next_xp == xp then break end
        if not isRubyAnnotation(xp) then
            local text = doc:getTextFromXPointers(xp, next_xp)
            if not text or text == "" or text:find("[\r\n]") then
                if chars[#chars] ~= Matcher.SEPARATOR then
                    chars[#chars + 1] = Matcher.SEPARATOR
                    info[#info + 1] = false
                end
            else
                local ruby = xp:find("/ruby") ~= nil
                for c in text:gmatch(util.UTF8_CHAR_PATTERN) do
                    chars[#chars + 1] = c
                    info[#info + 1] = { xp0 = xp, xp1 = next_xp, ruby = ruby }
                end
            end
        end
        xp = next_xp
    end
    return chars, info
end

local function furiganaFace(px)
    -- Font:getFace() scales its size by the screen DPI.
    local pt = math.max(5, math.floor(px * 100 / Screen:scaleBySize(100)))
    return Font:getFace("cfont", pt)
end

--- Furigana on the ruby side of the glyphs of `box` (`col` from glyphColumn()).
function Marker:_addFurigana(reading, box, col, vertical)
    if vertical then
        local px = math.max(6, math.floor(col.em * 0.5))
        local face = furiganaFace(px)
        local chars = util.splitToChars(reading)
        local widgets, total = {}, 0
        for i, c in ipairs(chars) do
            widgets[i] = TextWidget:new{ text = c, face = face, padding = 0 }
            total = total + widgets[i]:getSize().h
        end
        local y = box.y + math.floor((box.h - total) / 2)
        for _, w in ipairs(widgets) do
            local size = w:getSize()
            local x = col.hi
            table.insert(self.furigana, { widget = w, x = x, y = y })
            self:_extend(Geom:new{ x = x, y = y, w = size.w, h = size.h })
            y = y + size.h
        end
    else
        local px = math.max(6, math.floor(col.em * 0.5))
        local w = TextWidget:new{ text = reading, face = furiganaFace(px), padding = 0 }
        local size = w:getSize()
        local x = box.x + math.floor((box.w - size.w) / 2)
        local y = col.lo - size.h
        table.insert(self.furigana, { widget = w, x = x, y = y })
        self:_extend(Geom:new{ x = x, y = y, w = size.w, h = size.h })
    end
end

--- Where the glyphs are across a line box: the boxes span the whole line
-- height (line spacing included), the glyphs one em centered in it. The em
-- is estimated from the span's advance per character.
local function glyphColumn(boxes, length, vertical)
    local advance = 0
    for _, box in ipairs(boxes) do
        advance = advance + (vertical and box.h or box.w)
    end
    local box = boxes[1]
    local across = vertical and box.w or box.h
    local em = math.min(across, math.max(1, math.floor(advance / length)))
    local lo = (vertical and box.x or box.y) + math.floor((across - em) / 2)
    return { em = em, lo = lo, hi = lo + em }
end

function Marker:_extend(rect)
    self.region = self.region and self.region:combine(rect) or rect
end

function Marker:_clear()
    for _, f in ipairs(self.furigana) do f.widget:free() end
    self.marks, self.furigana, self.region = {}, {}, nil
end

function Marker:_compute()
    local start_time = time.now()
    self:_clear()
    local key = self:_cacheKey()
    local doc = self.ui.document
    local store = self.plugin.store
    local chars, info = self:_readPage()
    local read_time = time.now()

    local yomitan = self.ui.yomitan
    local match_at
    if yomitan and yomitan.matchAt and yomitan:isActive() then
        match_at = function(text) return yomitan:matchAt(text) end
    end
    local spans, calls = Matcher.matchPage(chars, store, match_at)

    local thickness = math.max(1, Screen:scaleBySize(2))
    local gap = math.max(1, Screen:scaleBySize(1))
    local found = {}
    local vertical = doc.isVerticalPage and doc:isVerticalPage(doc:getCurrentPage())
    for _, span in ipairs(spans) do
        local first, last = info[span.start], info[span.start + span.length - 1]
        if first and last then
            local boxes = doc:getScreenBoxesFromPositions(first.xp0, last.xp1, true)
            local ruby = false
            for j = span.start, span.start + span.length - 1 do
                if info[j] and info[j].ruby then ruby = true end
            end
            table.insert(found, { boxes = boxes, key = span.key, ruby = ruby, length = span.length })
        end
    end
    for _, item in ipairs(found) do
        if item.boxes[1] then
            local col = glyphColumn(item.boxes, item.length, vertical)
            for _, box in ipairs(item.boxes) do
                -- The mark goes beside the glyphs, opposite the furigana.
                local mark
                if vertical then
                    local x = col.lo + box.x - item.boxes[1].x - gap - thickness
                    mark = Geom:new{ x = x, y = box.y, w = thickness, h = box.h }
                else
                    local y = col.hi + box.y - item.boxes[1].y + gap
                    mark = Geom:new{ x = box.x, y = y, w = box.w, h = thickness }
                end
                table.insert(self.marks, mark)
                self:_extend(mark)
            end
            local word = store.words[item.key]
            if self.plugin.settings.furigana and word and not item.ruby
                    and word.reading ~= "" and word.reading ~= word.term and hasKanji(word.term) then
                self:_addFurigana(word.reading, item.boxes[1], col, vertical)
            end
        end
    end
    self.cache_key = key
    logger.dbg("bookwords: page marked:", #chars, "chars,", #spans, "words,", calls, "lookups;",
        time.to_ms(read_time - start_time), "ms reading,", time.to_ms(time.now() - read_time), "ms matching")
end

function Marker:free()
    self:_clear()
end

return Marker
