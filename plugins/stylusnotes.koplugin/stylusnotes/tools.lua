--[[--
What finished pen strokes do: ink is anchored and stored, highlighter strokes
highlight the text between their ends, eraser strokes remove the ink and the
highlights they touch.

@module stylusnotes.tools
]]

local Anchor = require("stylusnotes/anchor")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Tools = {}
Tools.__index = Tools

function Tools.new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui }, Tools)
end

function Tools:_repaint(xy, margin)
    local box = Anchor.bbox(xy, margin or 0)
    UIManager:setDirty(self.ui.dialog, "ui", Geom:new(box))
end

--- Anchor an ink stroke to the nearest text and store it.
function Tools:ink(stroke)
    local doc = self.ui.document
    local box = Anchor.bbox(stroke.xy)
    local cx, cy = math.floor(box.x + box.w / 2), math.floor(box.y + box.h / 2)
    local xp = doc:getXPointerFromScreenPoint(cx, cy)
    local metrics = xp and doc:getXPointerLineMetrics(xp)
    local anchored = metrics and Anchor.capture(stroke, metrics, self.plugin.layer:origin())
    if not anchored then
        logger.warn("stylusnotes: no text to anchor the stroke to at", cx, cy)
        self:_repaint(stroke.xy, 8) -- clear the live ink
        return
    end
    logger.dbg("stylusnotes: ink anchored at", xp, "ref", anchored.ref, "em", metrics.font_size,
        "vertical", metrics.vertical, "points", #stroke.xy / 2)
    self.plugin.store:addStroke{ xp = xp, ref = anchored.ref, pts = Anchor.encode(anchored.pts) }
    self:_repaint(stroke.xy, 8)
end

--- Highlight the text between the stroke's first and last points.
function Tools:highlight(stroke)
    local doc = self.ui.document
    local hl = self.ui.highlight
    local xy = stroke.xy
    local p0 = { x = xy[1], y = xy[2], page = doc:getCurrentPage() }
    local p1 = { x = xy[#xy - 1], y = xy[#xy], page = p0.page }
    local sel = doc:getTextFromPositions(p0, p1, true)
    if sel and sel.pos0 and sel.pos1 and sel.pos0 ~= sel.pos1 and sel.text and sel.text ~= "" then
        hl.selected_text = sel
        hl:saveHighlight()
        hl:clear()
        hl.selected_text = nil
        UIManager:setDirty(self.ui.dialog, "ui")
    else
        self:_repaint(xy, 4)
    end
end

--- Index of the highlight under a screen point, if any.
function Tools:highlightAt(x, y)
    for _, box in ipairs(self.ui.view.highlight.visible_boxes or {}) do
        local r = box.rect
        if x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h then
            return box.index
        end
    end
end

--- Remove the ink strokes and highlights the eraser path touches.
function Tools:erase(stroke)
    local xy = stroke.xy
    local radius = self.plugin.settings.eraser_radius
    local ids, nb_ink = {}, 0
    for _, p in ipairs(self.plugin.layer:getPlaced()) do
        for i = 1, #xy, 2 do
            if Anchor.hits(p.xy, xy[i], xy[i + 1], radius) then
                ids[p.id] = true
                nb_ink = nb_ink + 1
                break
            end
        end
    end
    if nb_ink > 0 then
        self.plugin.store:removeStrokes(ids)
    end
    local indexes, seen = {}, {}
    if self.plugin.settings.eraser_highlights then
        for i = 1, #xy, 2 do
            local index = self:highlightAt(xy[i], xy[i + 1])
            if index and not seen[index] then
                seen[index] = true
                table.insert(indexes, index)
            end
        end
        -- Indexes shift as items are removed.
        table.sort(indexes, function(a, b) return a > b end)
        for _, index in ipairs(indexes) do
            self.ui.highlight:deleteHighlight(index)
        end
    end
    logger.dbg("stylusnotes: erased", nb_ink, "strokes and", #indexes, "highlights")
    UIManager:setDirty(self.ui.dialog, "ui")
end

--- A short pen tap: open the highlight under it, if any.
function Tools:tap(x, y)
    local index = self:highlightAt(x, y)
    if index then
        self.ui.highlight:showHighlightNoteOrDialog(index)
        return true
    end
end

return Tools
