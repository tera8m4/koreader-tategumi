--[[--
Finds the recorded words in a page of text.

At every position starting with a character a recorded word can start with,
the text is matched the way a lookup there would match it (Yomitan's
deinflection, through `match_at`). The position is marked when that match is
a recorded word. Without `match_at`, or when it finds nothing, the recorded
forms are matched literally.

@module bookwords.matcher
]]

local Store = require("bookwords/store")

local Matcher = {}

Matcher.SEPARATOR = "\n" -- in `chars`: end of paragraph, nothing matches across it

--- @tparam {string,...} chars the page's characters (ruby text excluded)
-- @tparam Store store
-- @tparam func|nil match_at function(text) -> length, {{term=, reading=},...}
-- @tparam table opts {scan_length = 16, max_calls = 80}
-- @treturn {{start=, length=, key=},...} non-overlapping spans, in order
-- @treturn int number of match_at calls
function Matcher.matchPage(chars, store, match_at, opts)
    opts = opts or {}
    local scan_length = opts.scan_length or 16
    local max_calls = opts.max_calls or 80
    local first_chars = store:firstChars()
    local spans, calls = {}, 0
    local n = #chars
    local i = 1
    while i <= n do
        local length, key
        if first_chars[chars[i]] then
            local parts = {}
            for j = i, math.min(n, i + scan_length - 1) do
                if chars[j] == Matcher.SEPARATOR then break end
                parts[#parts + 1] = chars[j]
            end
            local text = table.concat(parts)
            local matched_other = false
            if match_at and calls < max_calls then
                calls = calls + 1
                local match_length, words = match_at(text)
                if match_length then
                    for _, word in ipairs(words) do
                        if store:has(word.term, word.reading) then
                            length, key = match_length, Store.key(word.term, word.reading)
                            break
                        end
                    end
                    -- A lookup here would show another word.
                    matched_other = length == nil
                end
            end
            if not length and not matched_other then
                length, key = store:matchSurface(text)
            end
        end
        if length then
            table.insert(spans, { start = i, length = length, key = key })
            i = i + length
        else
            i = i + 1
        end
    end
    return spans, calls
end

return Matcher
