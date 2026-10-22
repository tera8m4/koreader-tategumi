--[[--
Full-screen ruled sheet for writing a handwritten note with the pen.

Strokes are kept in sheet pixels while open, and saved scaled to a fixed
width (Store.NOTE_UNITS), so a note opened in another orientation or on
another screen is scaled to fit.

@module stylusnotes.canvas
]]

local Anchor = require("stylusnotes/anchor")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Live = require("stylusnotes/live")
local Store = require("stylusnotes/store")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local Screen = Device.screen

local Sheet = Widget:extend{
    strokes = nil, -- { {xy=, r=}, ... } in sheet pixels
    line_spacing = nil,
}

function Sheet:getSize()
    return self.dimen
end

function Sheet:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local ls = self.line_spacing
    for ly = y + ls, y + self.dimen.h - 1, ls do
        bb:paintRect(x, ly, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    end
    for _, s in ipairs(self.strokes) do
        local xy = {}
        for i = 1, #s.xy, 2 do
            xy[i] = s.xy[i] + x
            xy[i + 1] = s.xy[i + 1] + y
        end
        bb:paintStroke(xy, s.r, Blitbuffer.COLOR_BLACK)
    end
end

local NoteCanvas = InputContainer:extend{
    title = nil,
    note = nil, -- stored note to edit, or nil for a new one
    radius = 2,
    on_save = nil, -- function(note)
    extra_buttons = nil, -- optional row of buttons, called with the canvas closed
    covers_fullscreen = true,
}

--- Decode a stored note into sheet strokes for a sheet of width w.
function NoteCanvas.decodeNote(note, w)
    local strokes = {}
    if not note then return strokes end
    local s = w / Store.NOTE_UNITS
    for _, enc in ipairs(note.strokes or {}) do
        local pts = Anchor.decode(enc)
        local xy, r = {}, {}
        for i = 1, #pts, 3 do
            xy[#xy + 1] = math.floor(pts[i] * s + 0.5)
            xy[#xy + 1] = math.floor(pts[i + 1] * s + 0.5)
            r[#r + 1] = math.max(1, math.floor(pts[i + 2] * s + 0.5))
        end
        table.insert(strokes, { xy = xy, r = r })
    end
    return strokes
end

--- Encode sheet strokes of a sheet of width w as a stored note.
function NoteCanvas.encodeNote(strokes, w, h)
    local s = Store.NOTE_UNITS / w
    local enc = {}
    for _, st in ipairs(strokes) do
        local pts = {}
        for i = 1, #st.xy, 2 do
            pts[#pts + 1] = math.floor(st.xy[i] * s + 0.5)
            pts[#pts + 1] = math.floor(st.xy[i + 1] * s + 0.5)
            pts[#pts + 1] = math.floor(st.r[(i + 1) / 2] * s + 0.5)
        end
        table.insert(enc, Anchor.encode(pts))
    end
    return { w = Store.NOTE_UNITS, h = math.floor(h * s + 0.5), strokes = enc }
end

function NoteCanvas:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.titlebar = TitleBar:new{
        width = sw,
        align = "left",
        with_bottom_line = true,
        title = self.title or _("Handwritten note"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local rows = {
        {
            { text = _("Cancel"), callback = function() self:onClose() end },
            { text = _("Undo"), callback = function() self:undo() end },
            { text = _("Clear"), callback = function() self:clear() end },
            { text = _("Save"), callback = function() self:save() end },
        },
    }
    if self.extra_buttons then
        local row = {}
        for _, b in ipairs(self.extra_buttons) do
            table.insert(row, {
                text = b.text,
                callback = function()
                    UIManager:close(self)
                    b.callback()
                end,
            })
        end
        table.insert(rows, 1, row)
    end
    self.button_table = ButtonTable:new{
        width = sw,
        buttons = rows,
        zero_sep = true,
        show_parent = self,
    }
    local sheet_h = sh - self.titlebar:getHeight() - self.button_table:getSize().h
    self.sheet = Sheet:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sheet_h },
        strokes = NoteCanvas.decodeNote(self.note, sw),
        line_spacing = Screen:scaleBySize(48),
    }
    self.live = Live.new{
        radius = self.radius,
        clip = self.sheet.dimen,
        on_finish = function(stroke) self:_onStroke(stroke) end,
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            self.titlebar,
            self.sheet,
            self.button_table,
        },
    }
end

--- Whether a screen point is on the sheet (where the pen writes).
function NoteCanvas:isOnSheet(x, y)
    local d = self.sheet.dimen
    return x >= d.x and y >= d.y and x < d.x + d.w and y < d.y + d.h
end

--- Stylus input while the canvas is shown (see the plugin's router).
function NoteCanvas:feedStylus(slot, tool)
    self.live:feed(slot, tool)
end

function NoteCanvas:_onStroke(stroke)
    local d = self.sheet.dimen
    local xy = {}
    for i = 1, #stroke.xy, 2 do
        xy[i] = stroke.xy[i] - d.x
        xy[i + 1] = stroke.xy[i + 1] - d.y
    end
    if stroke.tool == "eraser" then
        local kept = {}
        for _, s in ipairs(self.sheet.strokes) do
            local hit = false
            for i = 1, #xy, 2 do
                if Anchor.hits(s.xy, xy[i], xy[i + 1], Screen:scaleBySize(12)) then
                    hit = true
                    break
                end
            end
            if not hit then table.insert(kept, s) end
        end
        self.sheet.strokes = kept
        self:_repaintSheet()
    else
        table.insert(self.sheet.strokes, { xy = xy, r = stroke.r })
        self.dirty = true
    end
end

function NoteCanvas:_repaintSheet()
    self.dirty = true
    UIManager:setDirty(self, "ui", self.sheet.dimen)
end

function NoteCanvas:undo()
    if #self.sheet.strokes > 0 then
        table.remove(self.sheet.strokes)
        self:_repaintSheet()
    end
end

function NoteCanvas:clear()
    if #self.sheet.strokes > 0 then
        self.sheet.strokes = {}
        self:_repaintSheet()
    end
end

function NoteCanvas:save()
    self.live:finish()
    local note = #self.sheet.strokes > 0
        and NoteCanvas.encodeNote(self.sheet.strokes, self.sheet.dimen.w, self.sheet.dimen.h)
        or nil
    UIManager:close(self)
    if self.on_save then
        self.on_save(note)
    end
end

function NoteCanvas:onClose()
    self.live:cancel()
    UIManager:close(self)
    return true
end

function NoteCanvas:onShow()
    UIManager:setDirty(self, "full")
end

function NoteCanvas:onCloseWidget()
    if self.on_closed then self.on_closed() end
    UIManager:setDirty(nil, "full")
end

return NoteCanvas
