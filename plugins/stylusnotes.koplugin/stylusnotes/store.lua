--[[--
Per-book storage of ink strokes and handwritten notes, kept in the book's
doc settings (so it moves, syncs and is purged with the book).

Points are stored as compact delta strings (see stylusnotes.anchor), so
heavily annotated books stay small.

* page ink: strokes = { {id=, xp=, ref=, pts=}, ... }
* handwritten notes: notes = { [note_id] = { w=, h=, strokes = { pts, ... } } }
  where note points are in canvas pixels scaled to a width of NOTE_UNITS.

@module stylusnotes.store
]]

local SETTING_KEY = "stylusnotes"

local Store = {
    NOTE_UNITS = 4096,
}
Store.__index = Store

function Store.load(doc_settings)
    local data = doc_settings:readSetting(SETTING_KEY) or {}
    local self = setmetatable({
        strokes = data.strokes or {},
        notes = data.notes or {},
        next_id = data.next_id or 1,
        version = 0,
        dirty = false,
    }, Store)
    -- Ids may be missing from hand-edited or merged data.
    for _, s in ipairs(self.strokes) do
        if not s.id or s.id >= self.next_id then
            s.id = s.id or self.next_id
            self.next_id = s.id + 1
        end
    end
    return self
end

function Store:save(doc_settings)
    if not self.dirty then return end
    if #self.strokes == 0 and next(self.notes) == nil then
        doc_settings:delSetting(SETTING_KEY)
    else
        doc_settings:saveSetting(SETTING_KEY, {
            strokes = self.strokes,
            notes = self.notes,
            next_id = self.next_id,
        })
    end
    self.dirty = false
end

function Store:_changed()
    self.version = self.version + 1
    self.dirty = true
end

function Store:newId()
    local id = self.next_id
    self.next_id = id + 1
    return id
end

--- Add a page stroke {xp, ref, pts}; returns its id.
function Store:addStroke(stroke)
    stroke.id = self:newId()
    table.insert(self.strokes, stroke)
    self:_changed()
    return stroke.id
end

--- Remove page strokes by id (a set {id = true}); returns the number removed.
function Store:removeStrokes(ids)
    local kept, removed = {}, 0
    for _, s in ipairs(self.strokes) do
        if ids[s.id] then
            removed = removed + 1
        else
            kept[#kept + 1] = s
        end
    end
    if removed > 0 then
        self.strokes = kept
        self:_changed()
    end
    return removed
end

function Store:getNote(note_id)
    return note_id and self.notes[note_id]
end

--- Create or replace a handwritten note; returns its id.
function Store:setNote(note_id, note)
    note_id = note_id or ("n" .. self:newId())
    self.notes[note_id] = note
    self:_changed()
    return note_id
end

function Store:removeNote(note_id)
    if note_id and self.notes[note_id] then
        self.notes[note_id] = nil
        self:_changed()
    end
end

return Store
