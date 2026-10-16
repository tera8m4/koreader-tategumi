--[[--
A small Yomitan-style lookup popup: headword, short definition and one row
of buttons, placed on the half of the screen away from the looked-up word.

It has far fewer widgets than DictQuickLookup and refreshes only its own
area, so it opens faster. "Full" opens the regular dictionary window.

@module yomitan.popup
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local Popup = InputContainer:extend{
    results = nil, -- DictQuickLookup results with yomitan_short set
    word_boxes = nil, -- screen boxes of the looked-up word
    index = 1,
    on_full = nil, -- function(index): open the full window
    on_close = nil, -- function()
    on_tap_outside = nil, -- function(ges): after closing on a tap elsewhere
}

function Popup:init()
    local screen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.dimen = screen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            Next = { { Device.input.group.PgFwd } },
            Prev = { { Device.input.group.PgBack } },
        }
    end
    self:build()
end

function Popup:build()
    local r = self.results[self.index]
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = Size.margin.default
    local padding = Size.padding.large
    local border = Size.border.window
    local width = screen_w - 2 * margin
    local inner_w = width - 2 * (padding + border)

    local counter = TextWidget:new{
        text = #self.results > 1 and (self.index .. " / " .. #self.results) or "",
        face = Font:getFace("smallinfofont"),
    }
    local counter_w = counter:getSize().w
    local headword = TextWidget:new{
        text = r.word,
        face = Font:getFace("cfont", 24),
        bold = true,
        max_width = inner_w - counter_w - padding,
        lang = "ja",
    }
    local title = HorizontalGroup:new{
        align = "center",
        headword,
        HorizontalSpan:new{ width = inner_w - headword:getSize().w - counter_w },
        counter,
    }

    local buttons = ButtonTable:new{
        width = inner_w,
        zero_sep = true,
        show_parent = self,
        buttons = {{
            {
                text = "◀",
                enabled = self.index > 1,
                callback = function() self:onPrev() end,
            },
            {
                text = _("Full"),
                callback = function()
                    self:close()
                    if self.on_full then self.on_full(self.index) end
                end,
            },
            {
                text = "▶",
                enabled = self.index < #self.results,
                callback = function() self:onNext() end,
            },
        }},
    }

    -- At most ~40% of the screen; "Full" shows the rest.
    local body_max_h = math.floor(screen_h * 0.4) - title:getSize().h - buttons:getSize().h
    local body_args = {
        text = r.yomitan_short or r.definition or "",
        face = Font:getFace("cfont", 20),
        width = inner_w,
        lang = "ja",
    }
    local body = TextBoxWidget:new(body_args)
    if body:getSize().h > body_max_h then
        body:free()
        body_args.height = body_max_h
        body_args.height_adjust = true
        body_args.height_overflow_show_ellipsis = true
        body = TextBoxWidget:new(body_args)
    end

    if self.frame then self.frame:free() end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        radius = Size.radius.window,
        padding = padding,
        VerticalGroup:new{
            align = "left",
            title,
            VerticalSpan:new{ width = Size.span.vertical_default },
            body,
            VerticalSpan:new{ width = Size.span.vertical_default },
            buttons,
        },
    }

    -- Away from the word: at the bottom if the word is in the upper half.
    local size = self.frame:getSize()
    local box = self.word_boxes and self.word_boxes[1]
    local y
    if box and box.y + box.h / 2 > screen_h / 2 then
        y = margin
    else
        y = screen_h - size.h - margin
    end
    self.frame_dimen = Geom:new{ x = margin, y = y, w = size.w, h = size.h }
    self[1] = self.frame
end

function Popup:paintTo(bb, x, y)
    self.frame:paintTo(bb, self.frame_dimen.x, self.frame_dimen.y)
end

function Popup:getVisibleArea()
    return self.frame_dimen
end

function Popup:show()
    UIManager:show(self, "ui", self.frame_dimen)
end

function Popup:changeResult(index)
    if index < 1 or index > #self.results or index == self.index then return true end
    local old = self.frame_dimen
    self.index = index
    self:build()
    -- Repaint everything under both the old and the new popup.
    UIManager:setDirty("all", "ui", old:combine(self.frame_dimen))
    return true
end

function Popup:onNext() return self:changeResult(self.index + 1) end
function Popup:onPrev() return self:changeResult(self.index - 1) end

function Popup:close()
    UIManager:close(self, "ui", self.frame_dimen)
    if self.on_close then self.on_close() end
end

function Popup:onClose()
    self:close()
    return true
end

function Popup:onTap(_, ges)
    if ges.pos:intersectWith(self.frame_dimen) then
        return true
    end
    self:close()
    if self.on_tap_outside then
        UIManager:nextTick(function() self.on_tap_outside(ges) end)
    end
    return true
end

function Popup:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then
        return self:onNext()
    elseif ges.direction == "east" or ges.direction == "south" then
        return self:onPrev()
    end
    return true
end

function Popup:onCloseWidget()
    if self.frame then self.frame:free() end
end

return Popup
