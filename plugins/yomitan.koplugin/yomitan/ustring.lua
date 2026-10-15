--[[--
Minimal UTF-8 helpers for the Yomitan port.

Yomitan works on JavaScript strings; here strings are UTF-8 byte strings, so
everything that Yomitan does per character is done per code point instead.

@module yomitan.ustring
]]

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local UString = {}

UString.CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

--- Split a string into an array of UTF-8 characters.
function UString.chars(s)
    local out = {}
    local n = 0
    for c in s:gmatch(UString.CHAR_PATTERN) do
        n = n + 1
        out[n] = c
    end
    return out
end

--- Number of UTF-8 characters in a string.
function UString.len(s)
    local n = 0
    for _ in s:gmatch(UString.CHAR_PATTERN) do
        n = n + 1
    end
    return n
end

--- Code point of a single UTF-8 character (the first one in c).
function UString.codepoint(c)
    local b1 = c:byte(1)
    if not b1 then return nil end
    if b1 < 0x80 then
        return b1
    elseif b1 < 0xE0 then
        return bor(lshift(band(b1, 0x1F), 6), band(c:byte(2) or 0, 0x3F))
    elseif b1 < 0xF0 then
        return bor(lshift(band(b1, 0x0F), 12), lshift(band(c:byte(2) or 0, 0x3F), 6), band(c:byte(3) or 0, 0x3F))
    else
        return bor(lshift(band(b1, 0x07), 18), lshift(band(c:byte(2) or 0, 0x3F), 12),
                   lshift(band(c:byte(3) or 0, 0x3F), 6), band(c:byte(4) or 0, 0x3F))
    end
end

--- UTF-8 encoding of a code point.
function UString.char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(bor(0xC0, rshift(cp, 6)), bor(0x80, band(cp, 0x3F)))
    elseif cp < 0x10000 then
        return string.char(bor(0xE0, rshift(cp, 12)), bor(0x80, band(rshift(cp, 6), 0x3F)), bor(0x80, band(cp, 0x3F)))
    else
        return string.char(bor(0xF0, rshift(cp, 18)), bor(0x80, band(rshift(cp, 12), 0x3F)),
                           bor(0x80, band(rshift(cp, 6), 0x3F)), bor(0x80, band(cp, 0x3F)))
    end
end

--- Plain (non-pattern) replacement of every occurrence of `from` by `to`.
function UString.replaceAll(s, from, to)
    if from == "" then return s end
    local init = 1
    local parts = {}
    local n = 0
    while true do
        local i, j = s:find(from, init, true)
        if not i then break end
        n = n + 1
        parts[n] = s:sub(init, i - 1)
        n = n + 1
        parts[n] = to
        init = j + 1
    end
    if n == 0 then return s end
    n = n + 1
    parts[n] = s:sub(init)
    return table.concat(parts)
end

--- Whether s ends with suffix (byte-wise, which is exact for UTF-8).
function UString.endsWith(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

--- Whether s starts with prefix.
function UString.startsWith(s, prefix)
    return s:sub(1, #prefix) == prefix
end

--- Whether a code point lies in one of the {min, max} ranges.
function UString.inRanges(cp, ranges)
    for i = 1, #ranges do
        local r = ranges[i]
        if cp >= r[1] and cp <= r[2] then
            return true
        end
    end
    return false
end

return UString
