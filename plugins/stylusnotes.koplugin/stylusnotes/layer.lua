--[[--
ReaderView module painting the stored ink of the current page.

Strokes on the page are found by comparing their anchor xpointers with the
page's start and end (DOM order, no layout needed), then placed from their
anchors' current line metrics. The placed strokes are cached per page,
rendering and store version.

@module stylusnotes.layer
]]

local Anchor = require("stylusnotes/anchor")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local Layer = {}
Layer.__index = Layer

function Layer.new(plugin)
    return setmetatable({ plugin = plugin, ui = plugin.ui, placed = {} }, Layer)
end

function Layer:isActive()
    return self.plugin.store and self.ui.view and self.ui.view.view_mode == "page"
end

function Layer:_cacheKey()
    local doc = self.ui.document
    return table.concat({
        doc:getCurrentPage(),
        doc:getDocumentRenderingHash(),
        self.plugin.store.version,
    }, ":")
end

function Layer:invalidate()
    self.cache_key = nil
end

--- Screen origin of a document point, as needed by stylusnotes.anchor.
function Layer:origin()
    local doc = self.ui.document
    return function(block, inline)
        return doc:docToScreenPoint(block, inline)
    end
end

--- Whether xp is on the current page(s).
function Layer:_onPageFunc()
    local doc = self.ui.document
    local page = doc:getCurrentPage()
    local start_xp = doc:getPageXPointer(page)
    local end_xp = doc:getPageXPointer(page + doc:getVisiblePageCount())
    if end_xp == start_xp then end_xp = nil end -- last page
    return function(xp)
        if start_xp then
            local c = doc:compareXPointers(start_xp, xp)
            if not c or c < 0 then return false end -- invalid, or before the page
        end
        if end_xp and doc:compareXPointers(xp, end_xp) ~= 1 then return false end -- at/after the next page
        return true
    end
end

--- Place one stored stroke on screen: {id, xy, radii} or nil.
function Layer:place(stroke)
    local metrics = self.ui.document:getXPointerLineMetrics(stroke.xp)
    if not metrics then return end
    stroke._pts = stroke._pts or Anchor.decode(stroke.pts)
    local xy, radii = Anchor.place({ ref = stroke.ref, pts = stroke._pts }, metrics, self:origin())
    if not xy then return end
    return { id = stroke.id, xy = xy, radii = radii }
end

function Layer:_compute()
    local placed = {}
    local onPage = self:_onPageFunc()
    for _, stroke in ipairs(self.plugin.store.strokes) do
        if onPage(stroke.xp) then
            local p = self:place(stroke)
            if p then placed[#placed + 1] = p end
        end
    end
    self.placed = placed
end

--- Placed strokes of the current page (computing them if needed).
function Layer:getPlaced()
    if not self:isActive() then return {} end
    local key = self:_cacheKey()
    if key ~= self.cache_key then
        local ok, err = pcall(self._compute, self)
        if not ok then
            logger.warn("stylusnotes: placing ink failed", err)
            self.placed = {}
        end
        self.cache_key = key
    end
    return self.placed
end

function Layer:paintTo(bb, x, y)
    if not self.plugin.settings.show_ink then return end
    for _, p in ipairs(self:getPlaced()) do
        local xy = p.xy
        if x ~= 0 or y ~= 0 then
            xy = {}
            for i = 1, #p.xy, 2 do
                xy[i] = p.xy[i] + x
                xy[i + 1] = p.xy[i + 1] + y
            end
        end
        bb:paintStroke(xy, p.radii, Blitbuffer.COLOR_BLACK)
    end
end

return Layer
