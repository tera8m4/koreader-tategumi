--[[--
Plain-text rendering of dictionary entries, for the short popup view.

Plain text is laid out much faster than HTML, so the popup appears sooner.
Images, ruby readings and the parts of structured content listed in
SKIP_CONTENT (examples, notes, attribution) are left out; the full HTML
entry is one tap away.

@module yomitan.text
]]

local Text = {}

-- data-content values of structured content left out of the short view
-- (the names used by Jitendex).
local SKIP_CONTENT = {
    ["attribution"] = true,
    ["example-sentence"] = true,
    ["extra-info"] = true,
    ["forms"] = true,
}

local BLOCK = {
    details = true, div = true, li = true, ol = true, p = true,
    summary = true, table = true, tr = true, ul = true,
}

local function newline(buf)
    local last = buf[#buf]
    if last and last:sub(-1) ~= "\n" then
        buf[#buf + 1] = "\n"
    end
end

local function children(content)
    if type(content) == "table" and content.tag == nil and content.type == nil then
        return content
    end
    return { content }
end

local function append(buf, node)
    if type(node) == "string" then
        buf[#buf + 1] = node
        return
    elseif type(node) ~= "table" then
        return
    end
    local tag = node.tag
    if tag == nil then
        for _, child in ipairs(node) do append(buf, child) end
        return
    end
    local data = type(node.data) == "table" and node.data or nil
    if (data and SKIP_CONTENT[data.content]) or tag == "img" or tag == "rt" or tag == "rp" then
        return
    end
    if tag == "br" then
        buf[#buf + 1] = "\n"
    elseif data and data.content == "glossary" then
        -- One line per sense: "to eat; to live on"
        local parts = {}
        for _, child in ipairs(children(node.content)) do
            local sub = {}
            append(sub, type(child) == "table" and child.tag == "li" and child.content or child)
            local s = table.concat(sub):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
            if s ~= "" then table.insert(parts, s) end
        end
        buf[#buf + 1] = table.concat(parts, "; ")
    elseif tag == "ul" or tag == "ol" then
        local n = 0
        newline(buf)
        for _, child in ipairs(children(node.content)) do
            if type(child) == "table" and child.tag == "li" then
                n = n + 1
                newline(buf)
                if tag == "ol" then buf[#buf + 1] = n .. ". " end
                append(buf, child.content)
            else
                append(buf, child)
            end
        end
        newline(buf)
    elseif tag == "span" and data and data.class == "tag" then
        local sub = {}
        append(sub, node.content)
        buf[#buf + 1] = "[" .. table.concat(sub) .. "] "
    else
        if BLOCK[tag] then newline(buf) end
        append(buf, node.content)
        if BLOCK[tag] then newline(buf) end
    end
end

local function glossaryItem(item)
    if type(item) == "string" then
        return item
    elseif type(item) == "table" then
        if item.type == "structured-content" then
            local buf = {}
            append(buf, item.content)
            return table.concat(buf)
        elseif item.type == "text" and type(item.text) == "string" then
            return item.text
        end
    end
    return nil
end

local function tagNames(tags)
    local out = {}
    for _, tag in ipairs(tags) do
        if not tag.redundant then table.insert(out, "[" .. tag.name .. "]") end
    end
    return table.concat(out, " ")
end

--- Plain-text counterpart of Html.entryForDictionary().
function Text.entryForDictionary(entry, dictionary)
    local lines = {}
    for _, chain in ipairs(entry.inflection_rule_chain_candidates) do
        if #chain.inflection_rules > 0 then
            local names = {}
            for i, rule in ipairs(chain.inflection_rules) do names[i] = rule.name end
            table.insert(lines, "« " .. table.concat(names, " « "))
        end
    end
    for _, hw in ipairs(entry.headwords) do
        local t = tagNames(hw.tags)
        if t ~= "" then table.insert(lines, t) end
    end
    for _, definition in ipairs(entry.definitions) do
        if definition.dictionary == dictionary then
            local t = tagNames(definition.tags)
            if t ~= "" then table.insert(lines, t) end
            for _, glossary in ipairs(definition.entries) do
                local s = glossaryItem(glossary)
                if s then table.insert(lines, s) end
            end
        end
    end
    local text = table.concat(lines, "\n")
    text = text:gsub("[ \t]*\n[ \t]*", "\n"):gsub("\n\n+", "\n"):gsub("^\n+", ""):gsub("\n+$", "")
    return text
end

return Text
