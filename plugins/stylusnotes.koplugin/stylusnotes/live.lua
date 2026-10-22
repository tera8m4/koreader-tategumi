--[[--
Low-latency stroke capture: pen samples are painted straight to the
framebuffer and refreshed with the A2 waveform, bypassing the widget repaint.
Finished strokes are handed to a callback, which stores them and asks for a
regular repaint.

@module stylusnotes.live
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local time = require("ui/time")
local Screen = Device.screen

local REFRESH_INTERVAL = time.ms(20)

local Live = {}
Live.__index = Live

--[[--
@param opts {
    radius = base pen half-width (px),
    on_finish = function(stroke) with stroke = {tool, xy, r, bbox},
    clip = optional Geom limiting where ink is painted (e.g., a canvas),
}
--]]
function Live.new(opts)
    return setmetatable({
        radius = opts.radius or 2,
        on_finish = opts.on_finish,
        clip = opts.clip,
        pressure_max = 4095,
    }, Live)
end

function Live:setRadius(radius)
    self.radius = radius
end

function Live:_radiusFor(pressure)
    if not pressure or pressure <= 0 then
        return self.radius
    end
    if pressure > self.pressure_max then
        self.pressure_max = pressure -- digitizer range not known in advance
    end
    local f = 0.5 + pressure / self.pressure_max
    return math.max(1, math.floor(self.radius * f + 0.5))
end

function Live:_inClip(x, y)
    local c = self.clip
    return not c or (x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h)
end

function Live:_grow(x, y, r)
    local d = self.dirty
    if not d then
        self.dirty = { x0 = x - r, y0 = y - r, x1 = x + r, y1 = y + r }
        return
    end
    if x - r < d.x0 then d.x0 = x - r end
    if y - r < d.y0 then d.y0 = y - r end
    if x + r > d.x1 then d.x1 = x + r end
    if y + r > d.y1 then d.y1 = y + r end
end

function Live:_flush(force)
    local d = self.dirty
    if not d then return end
    local now = time.now()
    if not force and self.last_refresh and now - self.last_refresh < REFRESH_INTERVAL then
        return
    end
    self.last_refresh = now
    self.dirty = nil
    local x, y = math.max(0, d.x0), math.max(0, d.y0)
    local w = math.min(Screen:getWidth(), d.x1 + 1) - x
    local h = math.min(Screen:getHeight(), d.y1 + 1) - y
    if w > 0 and h > 0 then
        Screen:refreshA2(x, y, w, h)
    end
end

--- Whether a stroke is being drawn.
function Live:isActive()
    return self.stroke ~= nil
end

--[[--
Feed one routed stylus slot (see Input:registerStylusCallback).
@param tool the tool this stroke is for (fixed at pen down)
--]]
function Live:feed(slot, tool)
    local down = slot.id ~= nil and slot.id ~= -1
    if not down then
        self:finish()
        return
    end
    if not (slot.x and slot.y) then return end
    local x, y = Device.input:stylusToScreen(slot.x, slot.y)
    local stroke = self.stroke
    if not stroke then
        if not self:_inClip(x, y) then return end
        stroke = { tool = tool, xy = {}, r = {} }
        self.stroke = stroke
    end
    local n = #stroke.xy
    if n > 0 and math.abs(stroke.xy[n - 1] - x) < 1 and math.abs(stroke.xy[n] - y) < 1 then
        return
    end
    if not self:_inClip(x, y) then
        -- Leaving the canvas ends the stroke there.
        self:finish()
        return
    end
    local r = self:_radiusFor(slot.pressure)
    stroke.xy[n + 1] = x
    stroke.xy[n + 2] = y
    stroke.r[#stroke.r + 1] = r

    -- Live feedback: ink is drawn as it will look; the highlighter and the
    -- eraser leave a thin trace until the page is repainted.
    local paint_r, color = r, Blitbuffer.COLOR_BLACK
    if stroke.tool ~= "ink" then
        paint_r = 1
        color = stroke.tool == "eraser" and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
    end
    local seg
    if n > 0 then
        seg = { stroke.xy[n - 1], stroke.xy[n], x, y }
    else
        seg = { x, y }
    end
    Screen.bb:paintStroke(seg, paint_r, color)
    if n > 0 then self:_grow(stroke.xy[n - 1], stroke.xy[n], paint_r) end
    self:_grow(x, y, paint_r)
    self:_flush(false)
end

--- End the current stroke (pen lifted), and hand it over.
function Live:finish()
    local stroke = self.stroke
    if not stroke then return end
    self.stroke = nil
    self:_flush(true)
    if #stroke.xy >= 2 and self.on_finish then
        self.on_finish(stroke)
    end
end

--- Drop the current stroke without handing it over.
function Live:cancel()
    self.stroke = nil
    self.dirty = nil
end

return Live
