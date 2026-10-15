--[[--
Renders Yomitan dictionary entries as HTML for KOReader's dictionary popup.

Structured content follows Yomitan's StructuredContentGenerator
(ext/js/display/structured-content-generator.js): elements keep their
`gloss-sc-<tag>` classes, `data` becomes `data-sc-*` attributes and the style
object becomes inline CSS, so dictionary stylesheets (styles.css) keep
working. Some adaptations are needed because KOReader renders HTML with
MuPDF, which has no ruby layout, no <details> and no interactivity:

  - <rt> is drawn as small text after its base, in parentheses unless the
    dictionary already provides <rp>;
  - <details>/<summary> are always expanded;
  - collapsed images are shown inline;
  - internal "?query=..." links become bword:// links, which KOReader looks
    up when tapped.

@module yomitan.html
]]

local Html = {}

local function escape(s)
    return (tostring(s):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end
Html.escape = escape

local function escapeMultiline(s)
    return (escape(s):gsub("\r?\n", "<br/>"))
end

local function camelToKebab(s)
    return (s:gsub("%u", function(c) return "-" .. c:lower() end))
end

local function isArray(t)
    return type(t) == "table" and (t[1] ~= nil or next(t) == nil)
end

local function urlDecode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function queryParam(query, name)
    for pair in query:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if urlDecode(k) == name then
            return urlDecode(v)
        end
    end
end

-- Style object keys handled by Yomitan, mapped to CSS properties.
local STRING_STYLES = {
    "fontStyle", "fontWeight", "fontSize", "color", "background", "backgroundColor",
    "verticalAlign", "textAlign", "textEmphasis", "textShadow",
    "textDecorationStyle", "textDecorationColor",
    "borderColor", "borderStyle", "borderRadius", "borderWidth", "clipPath",
    "margin", "padding", "paddingTop", "paddingLeft", "paddingRight", "paddingBottom",
    "wordBreak", "whiteSpace", "cursor", "listStyleType",
}
local MARGIN_STYLES = { "marginTop", "marginLeft", "marginRight", "marginBottom" }

local function styleToCss(style)
    local parts = {}
    for _, key in ipairs(STRING_STYLES) do
        if type(style[key]) == "string" then
            table.insert(parts, camelToKebab(key) .. ":" .. style[key])
        end
    end
    local tdl = style.textDecorationLine
    if type(tdl) == "string" then
        table.insert(parts, "text-decoration:" .. tdl)
    elseif type(tdl) == "table" then
        table.insert(parts, "text-decoration:" .. table.concat(tdl, " "))
    end
    for _, key in ipairs(MARGIN_STYLES) do
        local v = style[key]
        if type(v) == "number" then
            table.insert(parts, camelToKebab(key) .. ":" .. v .. "em")
        elseif type(v) == "string" then
            table.insert(parts, camelToKebab(key) .. ":" .. v)
        end
    end
    return table.concat(parts, ";")
end
Html.styleToCss = styleToCss

local function dataAttributes(data)
    if type(data) ~= "table" then return "" end
    local keys = {}
    for k in pairs(data) do
        if type(k) == "string" then table.insert(keys, k) end
    end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        -- dataset key "sc" + Key -> attribute data-sc-key
        local key = k:sub(1, 1):upper() .. k:sub(2)
        local attr = "data-" .. camelToKebab("sc" .. key)
        if attr:match("^[%w%-]+$") then
            table.insert(out, string.format(' %s="%s"', attr, escape(tostring(data[k]))))
        end
    end
    return table.concat(out)
end

-- Images

-- Yomitan's image container uses a font size of 1em/14 unless sizeUnits is
-- "em", so plain sizes are effectively CSS pixels at a 14px base font.
local PX_PER_EM = 14
local MAX_IMAGE_WIDTH_EM = 18

function Html.image(data)
    local width = tonumber(data.width) or 100
    local height = tonumber(data.height) or 100
    local pw, ph = tonumber(data.preferredWidth), tonumber(data.preferredHeight)
    local inv_aspect
    if pw and ph and pw > 0 then
        inv_aspect = ph / pw
    else
        inv_aspect = width > 0 and height / width or 1
    end
    local used_width
    if pw then
        used_width = pw
    elseif ph then
        used_width = inv_aspect > 0 and ph / inv_aspect or ph
    else
        used_width = width
    end
    local em_width = used_width
    if not (data.sizeUnits == "em" and (pw or ph)) then
        em_width = used_width / PX_PER_EM
    end
    if em_width > MAX_IMAGE_WIDTH_EM then
        em_width = MAX_IMAGE_WIDTH_EM
    end
    local style = { string.format("width:%.3fem", em_width), string.format("height:%.3fem", em_width * inv_aspect) }
    if type(data.verticalAlign) == "string" then
        table.insert(style, "vertical-align:" .. data.verticalAlign)
    end
    if type(data.border) == "string" then
        table.insert(style, "border:" .. data.border)
    end
    local attrs = {
        string.format('src="%s"', escape("media/" .. tostring(data.path))),
        'class="gloss-image"',
        string.format('style="%s"', table.concat(style, ";")),
    }
    if type(data.alt) == "string" then
        table.insert(attrs, string.format('alt="%s"', escape(data.alt)))
    end
    if type(data.title) == "string" then
        table.insert(attrs, string.format('title="%s"', escape(data.title)))
    end
    return string.format('<span class="gloss-image-link"><img %s/></span>', table.concat(attrs, " "))
end

-- Structured content

local SIMPLE_CONTAINERS = {
    ruby = true, rt = true, rp = true, thead = true, tbody = true, tfoot = true, tr = true,
}
local STYLED_CONTAINERS = {
    div = true, span = true, ol = true, ul = true, li = true, details = true, summary = true, td = true, th = true,
}
-- MuPDF has no <details>/<summary>; render them as always-open blocks.
local TAG_SUBSTITUTES = { details = "div", summary = "div" }

local append -- forward declaration

local function hasChildTag(content, tag)
    if type(content) ~= "table" then return false end
    if content.tag ~= nil then return content.tag == tag end
    for _, item in ipairs(content) do
        if type(item) == "table" and item.tag == tag then return true end
    end
    return false
end

local function appendElement(buf, node, ctx)
    local tag = node.tag
    if tag == "br" then
        table.insert(buf, "<br/>")
        return
    end
    if tag == "img" then
        table.insert(buf, Html.image(node))
        return
    end
    if tag == "a" then
        local href = type(node.href) == "string" and node.href or ""
        local target
        if href:sub(1, 1) == "?" then
            local query = queryParam(href:sub(2), "query")
            target = query and ("bword://" .. query) or nil
        else
            target = href
        end
        table.insert(buf, '<a class="gloss-link"')
        if target then
            table.insert(buf, string.format(' href="%s"', escape(target)))
        end
        if type(node.lang) == "string" then
            table.insert(buf, string.format(' lang="%s"', escape(node.lang)))
        end
        table.insert(buf, "><span class=\"gloss-link-text\">")
        append(buf, node.content, ctx)
        table.insert(buf, "</span></a>")
        return
    end
    local is_table = tag == "table"
    if not (is_table or SIMPLE_CONTAINERS[tag] or STYLED_CONTAINERS[tag]) then
        return -- unknown tag, ignored like Yomitan does
    end
    if is_table then
        table.insert(buf, '<div class="gloss-sc-table-container">')
    end
    local html_tag = TAG_SUBSTITUTES[tag] or tag
    if tag == "rt" or tag == "rp" then
        html_tag = "span" -- no ruby layout in MuPDF
    elseif tag == "ruby" then
        html_tag = "span"
    end
    table.insert(buf, "<" .. html_tag .. ' class="gloss-sc-' .. tag .. '"')
    table.insert(buf, dataAttributes(node.data))
    if type(node.lang) == "string" then
        table.insert(buf, string.format(' lang="%s"', escape(node.lang)))
    end
    if tag == "td" or tag == "th" then
        if type(node.colSpan) == "number" then table.insert(buf, string.format(' colspan="%d"', node.colSpan)) end
        if type(node.rowSpan) == "number" then table.insert(buf, string.format(' rowspan="%d"', node.rowSpan)) end
    end
    if STYLED_CONTAINERS[tag] then
        if type(node.style) == "table" then
            local css = styleToCss(node.style)
            if css ~= "" then
                table.insert(buf, string.format(' style="%s"', escape(css)))
            end
        end
        if type(node.title) == "string" then
            table.insert(buf, string.format(' title="%s"', escape(node.title)))
        end
    end
    table.insert(buf, ">")
    if tag == "ruby" then
        ctx = setmetatable({ ruby_has_rp = hasChildTag(node.content, "rp") }, { __index = ctx })
    end
    local paren = tag == "rt" and not ctx.ruby_has_rp
    if paren then table.insert(buf, "(") end
    append(buf, node.content, ctx)
    if paren then table.insert(buf, ")") end
    table.insert(buf, "</" .. html_tag .. ">")
    if is_table then
        table.insert(buf, "</div>")
    end
end

append = function(buf, content, ctx)
    if type(content) == "string" then
        if #content > 0 then
            table.insert(buf, escapeMultiline(content))
        end
    elseif type(content) == "table" then
        if content.tag ~= nil then
            appendElement(buf, content, ctx)
        elseif isArray(content) then
            for _, item in ipairs(content) do
                append(buf, item, ctx)
            end
        end
    end
end

--- Render a structured-content node tree to an HTML string.
function Html.structuredContent(content)
    local buf = {}
    append(buf, content, {})
    return table.concat(buf)
end

--- Render one glossary item (string, image or structured content).
function Html.glossaryItem(item)
    if type(item) == "string" then
        return escapeMultiline(item)
    elseif type(item) == "table" then
        if item.type == "image" then
            local out = Html.image(item)
            if type(item.description) == "string" then
                out = out .. '<span class="gloss-image-description">' .. escapeMultiline(item.description) .. "</span>"
            end
            return out
        elseif item.type == "structured-content" then
            return Html.structuredContent(item.content)
        elseif item.type == "text" and type(item.text) == "string" then
            return escapeMultiline(item.text)
        end
    end
    return nil
end

-- Entries

local function tagsHtml(tags)
    local out = {}
    for _, tag in ipairs(tags) do
        if not tag.redundant then
            table.insert(out, string.format('<span class="tag" data-category="%s">%s</span>', escape(tag.category), escape(tag.name)))
        end
    end
    return table.concat(out, " ")
end

--- Text shown in the popup's headword line, e.g. "打ち込む【うちこむ】".
function Html.headwordText(entry)
    local parts = {}
    for _, hw in ipairs(entry.headwords) do
        if hw.reading ~= "" and hw.reading ~= hw.term then
            table.insert(parts, hw.term .. "【" .. hw.reading .. "】")
        else
            table.insert(parts, hw.term)
        end
    end
    return table.concat(parts, "・")
end

--- One line per inflection chain, like Yomitan's "« passive « -た" list.
function Html.inflectionChains(entry)
    local out = {}
    for _, chain in ipairs(entry.inflection_rule_chain_candidates) do
        if #chain.inflection_rules > 0 then
            local names = {}
            for i, rule in ipairs(chain.inflection_rules) do
                names[i] = escape(rule.name)
            end
            table.insert(out, '<div class="inflection-rule-chain" data-source="' .. escape(chain.source) .. '">'
                .. table.concat(names, " « ") .. "</div>")
        end
    end
    if #out == 0 then return "" end
    return '<div class="inflection-rule-chains">' .. table.concat(out) .. "</div>"
end

--- Render the definitions of `entry` that come from `dictionary`.
function Html.entryForDictionary(entry, dictionary)
    local buf = { '<div class="entry">', Html.inflectionChains(entry) }
    local headword_tags = {}
    for _, hw in ipairs(entry.headwords) do
        local t = tagsHtml(hw.tags)
        if t ~= "" then table.insert(headword_tags, t) end
    end
    if #headword_tags > 0 then
        table.insert(buf, '<div class="headword-tag-list">' .. table.concat(headword_tags, " ") .. "</div>")
    end
    local definitions = {}
    for _, definition in ipairs(entry.definitions) do
        if definition.dictionary == dictionary then
            table.insert(definitions, definition)
        end
    end
    local list_tag = #definitions > 1 and "ol" or "div"
    table.insert(buf, "<" .. list_tag .. ' class="definition-list">')
    for _, definition in ipairs(definitions) do
        local item_tag = list_tag == "ol" and "li" or "div"
        table.insert(buf, "<" .. item_tag .. ' class="definition-item" data-dictionary="' .. escape(dictionary) .. '">')
        local tags = tagsHtml(definition.tags)
        if tags ~= "" then
            table.insert(buf, '<div class="definition-tag-list">' .. tags .. "</div>")
        end
        if #entry.headwords > 1 and #definition.headword_indices < #entry.headwords then
            local only = {}
            for _, index in ipairs(definition.headword_indices) do
                local hw = entry.headwords[index + 1]
                if hw then table.insert(only, escape(hw.term)) end
            end
            if #only > 0 then
                table.insert(buf, '<div class="definition-disambiguation-list">(' .. table.concat(only, "・") .. ")</div>")
            end
        end
        local items = {}
        for _, glossary in ipairs(definition.entries) do
            local html = Html.glossaryItem(glossary)
            if html then table.insert(items, '<li class="gloss-item">' .. html .. "</li>") end
        end
        if #items == 1 then
            table.insert(buf, '<div class="gloss-list gloss-single">' .. items[1]:gsub("^<li", "<div"):gsub("</li>$", "</div>") .. "</div>")
        elseif #items > 0 then
            table.insert(buf, '<ul class="gloss-list">' .. table.concat(items) .. "</ul>")
        end
        table.insert(buf, "</" .. item_tag .. ">")
    end
    table.insert(buf, "</" .. list_tag .. "></div>")
    return table.concat(buf)
end

--- Base stylesheet; dictionary styles.css is appended after it.
Html.BASE_CSS = [[
.inflection-rule-chains { font-size: 0.85em; margin-bottom: 0.3em; }
.tag { font-size: 0.75em; border: 1px solid; padding: 0 0.25em; }
.headword-tag-list, .definition-tag-list { margin-bottom: 0.2em; }
.definition-list { margin-top: 0; }
.gloss-list { margin-top: 0.1em; margin-bottom: 0.3em; }
.gloss-sc-rt { font-size: 0.6em; }
.gloss-sc-table-container { display: block; }
.gloss-sc-table { border-collapse: collapse; }
.gloss-sc-th, .gloss-sc-td { border: 1px solid; padding: 0.25em; vertical-align: top; }
.gloss-sc-th, .gloss-sc-thead, .gloss-sc-tfoot { font-weight: bold; }
.gloss-sc-summary { font-weight: bold; }
.gloss-image-description { display: block; font-size: 0.85em; }
]]

return Html
