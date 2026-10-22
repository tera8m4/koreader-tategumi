--[[--
Stylus notes: ink on the page, pen highlighting and handwritten notes on
highlights, for crengine documents (EPUB...) on stylus devices such as the
Kindle Scribe.

Ink strokes are anchored to the nearest text (see stylusnotes/anchor.lua), so
they follow the text when the book is laid out again.

Pen input comes from Input:registerStylusCallback, before gesture detection:
a pen contact on the page (with the reader on top) or on the note sheet is
taken over by this plugin; elsewhere (menus, dialogs) the pen acts as a finger.

@module koplugin.stylusnotes
]]

local Anchor = require("stylusnotes/anchor")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Input = require("device/input")
local Layer = require("stylusnotes/layer")
local Live = require("stylusnotes/live")
local NoteCanvas = require("stylusnotes/canvas")
local Notification = require("ui/widget/notification")
local Store = require("stylusnotes/store")
local Tools = require("stylusnotes/tools")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local SETTINGS_KEY = "stylusnotes_settings"
local NOTE_PLACEHOLDER = "✎" -- typed note of a highlight that only has handwriting

local DEFAULTS = {
    enabled = true,
    show_ink = true,
    pen_radius = 2, -- device pixels -- unscaled_size_check: ignore
    eraser_highlights = true,
    palm_rejection = true,
    side_button = "eraser", -- or "highlight"
}

local PEN_MODES = {
    { id = "ink", text = _("Write") },
    { id = "highlight", text = _("Highlight") },
    { id = "eraser", text = _("Erase") },
}

local StylusNotes = WidgetContainer:extend{
    name = "stylusnotes",
    is_doc_only = true,
}

function StylusNotes:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self.settings.eraser_radius = self.settings.eraser_radius or Screen:scaleBySize(10)
    self.pen_mode = "ink"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function StylusNotes:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function StylusNotes:onDispatcherRegisterActions()
    Dispatcher:registerAction("stylusnotes_pen_ink", { category = "none", event = "StylusPenMode", arg = "ink",
        title = _("Stylus: write"), reader = true })
    Dispatcher:registerAction("stylusnotes_pen_highlight", { category = "none", event = "StylusPenMode", arg = "highlight",
        title = _("Stylus: highlight"), reader = true })
    Dispatcher:registerAction("stylusnotes_pen_eraser", { category = "none", event = "StylusPenMode", arg = "eraser",
        title = _("Stylus: erase"), reader = true })
    Dispatcher:registerAction("stylusnotes_toggle_ink", { category = "none", event = "StylusToggleInk",
        title = _("Stylus: show/hide ink"), reader = true })
end

function StylusNotes:onReaderReady()
    if not self.ui.rolling or not Device:isTouchDevice() then return end -- needs crengine text positions
    self.store = Store.load(self.ui.doc_settings)
    self.layer = Layer.new(self)
    self.tools = Tools.new(self)
    self.live = Live.new{
        radius = self.settings.pen_radius,
        on_finish = function(stroke) self:_onPageStroke(stroke) end,
    }
    self.ui.view:registerViewModule("stylusnotes", self.layer)
    self:_registerStylus()
end

function StylusNotes:_registerStylus()
    local input = Device.input
    if self.settings.enabled then
        self.stylus_callback = function(_, slot) return self:_route(slot) end
        input:registerStylusCallback(self.stylus_callback)
        input.stylus_palm_rejection = self.settings.palm_rejection
    else
        self:_unregisterStylus()
    end
end

function StylusNotes:_unregisterStylus()
    local input = Device.input
    if self.stylus_callback and input.stylus_callback == self.stylus_callback then
        input:unregisterStylusCallback()
    end
    self.stylus_callback = nil
    input.stylus_palm_rejection = nil
end

function StylusNotes:onCloseDocument()
    self:_unregisterStylus()
    if self.live then self.live:cancel() end
end

function StylusNotes:onSaveSettings()
    if self.store then
        self.store:save(self.ui.doc_settings)
    end
end

function StylusNotes:_toolFor(slot)
    if slot.tool == Input.TOOL_TYPE_ERASER then
        if Device.input.stylus_eraser_active and self.settings.side_button == "highlight" then
            return "highlight"
        end
        return "eraser"
    elseif slot.tool == Input.TOOL_TYPE_HIGHLIGHTER then
        return "highlight"
    end
    return self.pen_mode
end

--- Stylus router: decide per contact whether we take it over.
function StylusNotes:_route(slot)
    local down = slot.id ~= nil and slot.id ~= -1
    local contact = self.contact
    if not contact then
        if not down or not (slot.x and slot.y) then return false end -- hover
        local x, y = Device.input:stylusToScreen(slot.x, slot.y)
        local top = UIManager:getTopmostVisibleWidget()
        local target = false
        if self.canvas then
            if top == self.canvas and self.canvas:isOnSheet(x, y) then
                target = self.canvas
            end
        elseif top == self.ui and self.layer:isActive() then
            target = self.live
        end
        contact = { target = target, tool = self:_toolFor(slot) }
        self.contact = contact
    end
    if not down then self.contact = nil end
    if not contact.target then return false end -- the pen acts as a finger
    if contact.target == self.canvas then
        self.canvas:feedStylus(slot, contact.tool)
    else
        self.live:feed(slot, contact.tool)
    end
    return true
end

function StylusNotes:_onPageStroke(stroke)
    local ok, err = pcall(function()
        if stroke.tool == "ink" then
            local tap = Screen:scaleBySize(6)
            local box = Anchor.bbox(stroke.xy)
            if box.w <= tap and box.h <= tap and self.tools:tap(stroke.xy[1], stroke.xy[2]) then
                self.tools:_repaint(stroke.xy, 8)
                return
            end
            self.tools:ink(stroke)
        elseif stroke.tool == "highlight" then
            self.tools:highlight(stroke)
        elseif stroke.tool == "eraser" then
            self.tools:erase(stroke)
        end
    end)
    if not ok then
        logger.warn("stylusnotes: stroke failed", err)
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

function StylusNotes:refreshPage()
    if self.layer then self.layer:invalidate() end
    UIManager:setDirty(self.ui.dialog, "ui")
end

function StylusNotes:onStylusPenMode(mode)
    self.pen_mode = mode
    for __, m in ipairs(PEN_MODES) do
        if m.id == mode then
            Notification:notify(_("Stylus") .. ": " .. m.text)
        end
    end
    return true
end

function StylusNotes:onStylusToggleInk()
    self.settings.show_ink = not self.settings.show_ink
    self:saveSettings()
    self:refreshPage()
    return true
end

-- Rerendering, page turns and annotation changes are covered by the layer's
-- cache key (page, rendering hash, store version); highlights moving only
-- needs the repaint ReaderView already does.

function StylusNotes:onAnnotationsModified(items)
    -- A deleted highlight takes its handwritten note along.
    if self.store and items and items.index_modified and items.index_modified < 0 then
        local item = items[1]
        if item and item.ink_note then
            self.store:removeNote(item.ink_note)
        end
    end
end

--- Handwritten notes

function StylusNotes:_annotation(index)
    return self.ui.annotation.annotations[index]
end

function StylusNotes:editHandwriting(anno)
    if not self.store then return end
    local note = self.store:getNote(anno.ink_note)
    local extra
    if note then
        extra = {
            {
                text = _("Delete handwriting"),
                callback = function() self:_deleteHandwriting(anno) end,
            },
            {
                text = _("Typed note"),
                callback = function()
                    local index = self.ui.annotation:getItemIndex(anno)
                    if index then self.ui.highlight:editNote(index) end
                end,
            },
            {
                text = _("Highlight menu"),
                callback = function()
                    local index = self.ui.annotation:getItemIndex(anno)
                    if index then self.ui.highlight:showHighlightDialog(index) end
                end,
            },
        }
    end
    local title = anno.text and (anno.text:gsub("%s+", " "))
    self.canvas = NoteCanvas:new{
        title = title,
        note = note,
        radius = self.settings.pen_radius,
        extra_buttons = extra,
        on_save = function(new_note) self:_saveHandwriting(anno, new_note) end,
        on_closed = function() self.canvas = nil self.contact = nil end,
    }
    UIManager:show(self.canvas)
end

function StylusNotes:_saveHandwriting(anno, note)
    if not note then
        self:_deleteHandwriting(anno)
        return
    end
    anno.ink_note = self.store:setNote(anno.ink_note, note)
    local payload = { anno }
    if not anno.note or anno.note == "" then
        anno.note = NOTE_PLACEHOLDER
        payload.nb_highlights_added = -1
        payload.nb_notes_added = 1
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", payload))
    UIManager:setDirty(self.ui.dialog, "ui")
end

function StylusNotes:_deleteHandwriting(anno)
    if not anno.ink_note then return end
    self.store:removeNote(anno.ink_note)
    anno.ink_note = nil
    local payload = { anno }
    if anno.note == NOTE_PLACEHOLDER then
        anno.note = nil
        payload.nb_highlights_added = 1
        payload.nb_notes_added = -1
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", payload))
    UIManager:setDirty(self.ui.dialog, "ui")
end

function StylusNotes:onShowHighlightNote(index)
    local anno = self:_annotation(index)
    if self.store and anno and anno.ink_note and self.store:getNote(anno.ink_note) then
        self:editHandwriting(anno)
        return true
    end
end

function StylusNotes:onHighlightDialogButtons(row, index, close_dialog)
    local anno = self:_annotation(index)
    if not (self.store and anno) then return end
    table.insert(row, {
        text = anno.ink_note and _("Handwriting") or _("Handwrite note"),
        callback = function()
            close_dialog()
            self:editHandwriting(anno)
        end,
    })
end

--- Menu

function StylusNotes:addToMainMenu(menu_items)
    local mode_items = {}
    for _, m in ipairs(PEN_MODES) do
        table.insert(mode_items, {
            text = m.text,
            radio = true,
            checked_func = function() return self.pen_mode == m.id end,
            callback = function() self.pen_mode = m.id end,
        })
    end
    menu_items.stylusnotes = {
        text = _("Stylus notes"),
        sub_item_table = {
            {
                text = _("Use the stylus to write"),
                checked_func = function() return self.settings.enabled end,
                callback = function()
                    self.settings.enabled = not self.settings.enabled
                    self:saveSettings()
                    if self.store then self:_registerStylus() end
                end,
            },
            {
                text = _("Show ink"),
                checked_func = function() return self.settings.show_ink end,
                callback = function() self:onStylusToggleInk() end,
            },
            {
                text = _("Pen tip action"),
                sub_item_table = mode_items,
                separator = true,
            },
            {
                text_func = function()
                    return _("Pen width") .. ": " .. self.settings.pen_radius * 2
                end,
                sub_item_table_func = function()
                    local items = {}
                    for _, r in ipairs({ 1, 2, 3, 4, 6 }) do
                        table.insert(items, {
                            text = tostring(r * 2),
                            radio = true,
                            checked_func = function() return self.settings.pen_radius == r end,
                            callback = function()
                                self.settings.pen_radius = r
                                self:saveSettings()
                                if self.live then self.live:setRadius(r) end
                            end,
                        })
                    end
                    return items
                end,
            },
            {
                text = _("Side button highlights"),
                help_text = _("Hold the pen's side button to highlight instead of erasing."),
                checked_func = function() return self.settings.side_button == "highlight" end,
                callback = function()
                    self.settings.side_button = self.settings.side_button == "highlight" and "eraser" or "highlight"
                    self:saveSettings()
                end,
            },
            {
                text = _("Eraser removes highlights"),
                checked_func = function() return self.settings.eraser_highlights end,
                callback = function()
                    self.settings.eraser_highlights = not self.settings.eraser_highlights
                    self:saveSettings()
                end,
            },
            {
                text = _("Ignore touches while the pen is near"),
                checked_func = function() return self.settings.palm_rejection end,
                callback = function()
                    self.settings.palm_rejection = not self.settings.palm_rejection
                    self:saveSettings()
                    if self.store then self:_registerStylus() end
                end,
                separator = true,
            },
            {
                text = _("Delete ink on this page"),
                enabled_func = function() return self.layer ~= nil and #self.layer:getPlaced() > 0 end,
                callback = function()
                    local ids = {}
                    for _, p in ipairs(self.layer:getPlaced()) do ids[p.id] = true end
                    self.store:removeStrokes(ids)
                    self:refreshPage()
                end,
            },
        },
    }
end

return StylusNotes
