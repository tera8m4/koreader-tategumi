-- Dump the Yomitan transforms descriptor as JSON (for the demo page).
local d = dofile(arg[1])

local function str(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("%c", function(c)
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function enc(v)
    local t = type(v)
    if t == "string" then return str(v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if next(v) == nil or v[1] ~= nil then
            local out = {}
            for i = 1, #v do out[i] = enc(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do out[#out + 1] = str(tostring(k)) .. ":" .. enc(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

io.write(enc({ conditions = d.conditions, transforms = d.transforms }))
