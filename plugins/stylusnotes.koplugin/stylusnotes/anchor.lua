--[[--
Anchoring of ink strokes to text, so they follow reflows.

A stroke is stored relative to a text position (xpointer): every point is an
offset from that position's line, in logical axes (inline = along the line,
block = across lines), in units of the font size there. After the text is
laid out again (other font, size, margins or writing mode), the offsets are
scaled by the new font size and placed from the new position of the anchor.

Reference for the inline axis:
* "glyph": the anchor glyph (ink over or near the text),
* "start"/"end": the start/end edge of the paragraph's content box (ink in a
  margin, kept beside its line however long lines become).
The block axis is always relative to the top of the anchor's line.

Metrics (from CreDocument:getXPointerLineMetrics) are in document
coordinates: inline0/inline1 (glyph), block0/block1 (line box),
block_start/block_end (paragraph content box, inline axis), font_size.
Screen origins come from CreDocument:docToScreenPoint(block, inline).

This module is pure (no document access) so it can be unit tested.

@module stylusnotes.anchor
]]

local Anchor = {}

Anchor.QUANT = 64 -- stored offsets are in 1/64 em

local floor = math.floor

local function round(v)
    return floor(v + 0.5)
end

--- Screen delta (dx, dy) from the origin to logical offsets (inline, block).
function Anchor.toLogical(dx, dy, vertical)
    if vertical then
        -- vertical-rl: the inline axis runs down, the block axis runs leftward
        return dy, -dx
    end
    return dx, dy
end

--- Logical offsets (inline, block) to a screen delta (dx, dy).
function Anchor.toScreen(di, db, vertical)
    if vertical then
        return -db, di
    end
    return di, db
end

--- Inline document coordinate of the reference edge for a stroke.
function Anchor.refInline(metrics, ref)
    if ref == "start" then
        return metrics.block_start
    elseif ref == "end" then
        return metrics.block_end
    end
    return metrics.inline0
end

--[[--
Choose the inline reference for a stroke from its inline extent (document
coordinates): strokes fully outside the paragraph's content box are margin
strokes.
--]]
function Anchor.classify(metrics, inline_min, inline_max)
    if inline_max < metrics.block_start then
        return "start"
    elseif inline_min > metrics.block_end then
        return "end"
    end
    return "glyph"
end

--[[--
Anchor a stroke.

@param stroke {xy = {x1, y1, ...} screen points, r = {r1, ...} radii in px}
@param metrics line metrics of the anchor xpointer
@param origin function(block, inline) -> screen x, y (docToScreenPoint)
@treturn table {ref, em, pts} or nil when the anchor is not on screen
--]]
function Anchor.capture(stroke, metrics, origin)
    local em = metrics.font_size
    if not em or em <= 0 then return end
    local vertical = metrics.vertical
    -- Screen origin of the line top at the anchor glyph.
    local gx, gy = origin(metrics.block0, metrics.inline0)
    if not gx then return end
    -- Inline extent of the stroke, in document coordinates.
    local xy = stroke.xy
    local imin, imax = math.huge, -math.huge
    for i = 1, #xy, 2 do
        local di = Anchor.toLogical(xy[i] - gx, xy[i + 1] - gy, vertical)
        local inline = metrics.inline0 + di
        if inline < imin then imin = inline end
        if inline > imax then imax = inline end
    end
    local ref = Anchor.classify(metrics, imin, imax)
    local shift = Anchor.refInline(metrics, ref) - metrics.inline0
    local q = Anchor.QUANT / em
    local pts = {}
    for i = 1, #xy, 2 do
        local di, db = Anchor.toLogical(xy[i] - gx, xy[i + 1] - gy, vertical)
        pts[#pts + 1] = round((di - shift) * q)
        pts[#pts + 1] = round(db * q)
        pts[#pts + 1] = round((stroke.r and stroke.r[(i + 1) / 2] or 1) * q)
    end
    return { ref = ref, pts = pts }
end

--[[--
Place an anchored stroke on screen.

@param anchored {ref, pts}
@param metrics current line metrics of the anchor xpointer
@param origin function(block, inline) -> screen x, y
@treturn table xy, table radii, or nil when the anchor is not on screen
--]]
function Anchor.place(anchored, metrics, origin)
    local em = metrics.font_size
    if not em or em <= 0 then return end
    local ox, oy = origin(metrics.block0, Anchor.refInline(metrics, anchored.ref))
    if not ox then return end
    local vertical = metrics.vertical
    local s = em / Anchor.QUANT
    local pts = anchored.pts
    local xy, radii = {}, {}
    for i = 1, #pts, 3 do
        local dx, dy = Anchor.toScreen(pts[i] * s, pts[i + 1] * s, vertical)
        xy[#xy + 1] = round(ox + dx)
        xy[#xy + 1] = round(oy + dy)
        radii[#radii + 1] = math.max(1, round(pts[i + 2] * s))
    end
    return xy, radii
end

--- Encode anchored points {u, v, w, ...} as a compact delta string.
function Anchor.encode(pts)
    local out = {}
    local pu, pv, pw = 0, 0, 0
    for i = 1, #pts, 3 do
        local u, v, w = pts[i], pts[i + 1], pts[i + 2]
        out[#out + 1] = string.format("%d %d %d", u - pu, v - pv, w - pw)
        pu, pv, pw = u, v, w
    end
    return table.concat(out, " ")
end

--- Decode a string from Anchor.encode.
function Anchor.decode(s)
    local pts = {}
    local acc = { 0, 0, 0 }
    local k = 0
    for num in (s or ""):gmatch("%-?%d+") do
        local j = k % 3 + 1
        acc[j] = acc[j] + tonumber(num)
        pts[#pts + 1] = acc[j]
        k = k + 1
    end
    return pts
end

--- Squared distance from point (px, py) to segment (ax, ay)-(bx, by).
function Anchor.segmentDistance2(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local cx, cy = ax + t * dx - px, ay + t * dy - py
    return cx * cx + cy * cy
end

--- Whether a screen polyline passes within dist of point (px, py).
function Anchor.hits(xy, px, py, dist)
    local d2 = dist * dist
    local n = #xy
    if n == 2 then
        local dx, dy = xy[1] - px, xy[2] - py
        return dx * dx + dy * dy <= d2
    end
    for i = 1, n - 3, 2 do
        if Anchor.segmentDistance2(px, py, xy[i], xy[i + 1], xy[i + 2], xy[i + 3]) <= d2 then
            return true
        end
    end
    return false
end

--- Bounding box {x, y, w, h} of screen points, grown by margin.
function Anchor.bbox(xy, margin)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #xy, 2 do
        local x, y = xy[i], xy[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    margin = margin or 0
    return { x = x0 - margin, y = y0 - margin, w = x1 - x0 + 2 * margin + 1, h = y1 - y0 + 2 * margin + 1 }
end

return Anchor
