--[[--
Reads the text following a document position for Yomitan-style scanning.

Like Yomitan's TextScanner, it collects up to `scan_length` characters from
the tapped position. Ruby annotations (<rt>/<rp>, i.e. furigana) are
skipped, so that "漢字" with furigana scans as 漢字 rather than 漢かん字じ;
the character end positions are kept so that a match length can be mapped
back to a document range.

The callbacks are the ones LanguageSupport hands to language plugins:
get_next_char_pos(xp) and get_text_in_range(xp0, xp1).

@module yomitan.scanner
]]

local UString = require("yomitan/ustring")

local Scanner = {}

--- Whether an XPointer points into ruby annotation text.
function Scanner.isRubyAnnotation(xpointer)
    if type(xpointer) ~= "string" then return false end
    return xpointer:find("/r[tp]%f[^%w]") ~= nil
end

--- Scan forward from pos0.
-- @treturn string the scanned text (without ruby annotations)
-- @treturn table end_positions[i] is the XPointer just after the i-th character
function Scanner.scan(callbacks, pos0, scan_length)
    local chars = {}
    local end_positions = {}
    -- Ruby text is only skipped when the scan starts on base text: if the
    -- user taps the furigana itself, scan the furigana.
    local skip_ruby = not Scanner.isRubyAnnotation(pos0)
    local current = pos0
    -- Bound the number of steps, as ruby annotations do not count towards
    -- the scan length.
    local max_steps = scan_length * 4 + 8
    local steps = 0
    local last_start -- where the last scanned character starts
    while #chars < scan_length and steps < max_steps do
        steps = steps + 1
        local next_pos = callbacks.get_next_char_pos(current)
        if not next_pos or next_pos == current then
            break
        end
        local text = callbacks.get_text_in_range(current, next_pos)
        if not text or text:find("[\r\n]") then
            -- End of the paragraph: nothing can match across it.
            break
        end
        if text == "" then
            -- From the end of a text node to the start of the next one: an
            -- inline element boundary (such as <ruby>) or the end of the
            -- paragraph, which a range reaching into the next text shows as
            -- a newline.
            local after = last_start and callbacks.get_next_char_pos(next_pos)
            local span = after and callbacks.get_text_in_range(last_start, after)
            if span and span:find("[\r\n]") then
                break
            end
        elseif not (skip_ruby and Scanner.isRubyAnnotation(current)) then
            last_start = current
            for _, c in ipairs(UString.chars(text)) do
                if #chars >= scan_length then break end
                table.insert(chars, c)
                end_positions[#chars] = next_pos
            end
        end
        current = next_pos
    end
    return table.concat(chars), end_positions
end

return Scanner
