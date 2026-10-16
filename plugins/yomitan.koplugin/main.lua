--[[--
Yomitan-compatible Japanese dictionary lookups.

This plugin replaces StarDict lookups for Japanese text with a port of
Yomitan's term lookup: text scanning from the long-pressed character,
deinflection, text preprocessing, grouping and sorting are ported from
Yomitan (https://github.com/yomidevs/yomitan), and dictionaries are Yomitan
dictionaries converted with tools/yomitan_convert.py.

It hooks into KOReader in two places:
  - LanguageSupport (onWordSelection) to select the matched text;
  - ReaderDictionary:setLookupBackend() to answer lookups.
On builds without these hooks, yomitan/compat.lua installs equivalents.

@module koplugin.yomitan
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Screen = Device.screen
local LanguageSupport = require("languagesupport")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Compat = require("yomitan/compat")
local Dictionary = require("yomitan/db")
local Html = require("yomitan/html")
local Japanese = require("yomitan/japanese")
local Scanner = require("yomitan/scanner")
local Text = require("yomitan/text")
local Translator = require("yomitan/translator")

local fullDefinition -- defined below

local DEFAULT_SCAN_LENGTH = 16 -- Yomitan's default scanning.length
local SETTINGS_KEY = "yomitan"

-- Dictionaries are opened once and shared by all plugin instances (reader
-- and file manager); connections are read-only.
local opened_dictionaries = {} -- folder name -> Dictionary
local open_errors = {} -- folder name -> error message

local Yomitan = WidgetContainer:extend{
    name = "yomitan",
    pretty_name = "Yomitan",
}

function Yomitan:getDataDir()
    return DataStorage:getDataDir() .. "/data/yomitan"
end

function Yomitan:readSettings()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    settings.dicts_order = settings.dicts_order or {}
    settings.dicts_disabled = settings.dicts_disabled or {}
    settings.scan_length = settings.scan_length or DEFAULT_SCAN_LENGTH
    settings.result_mode = settings.result_mode or "group"
    if settings.no_flash == nil then settings.no_flash = true end
    if settings.tap_lookup == nil then settings.tap_lookup = true end
    if settings.short_view == nil then settings.short_view = true end
    if settings.mini_popup == nil then settings.mini_popup = true end
    if settings.fast_refresh == nil then settings.fast_refresh = true end
    Compat.no_flash = settings.no_flash
    self.settings = settings
end

function Yomitan:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

--- Find dictionary folders (containing dict.sqlite3) and open them.
function Yomitan:discoverDictionaries()
    local dir = self:getDataDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        util.makePath(dir)
    end
    local found = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and lfs.attributes(dir .. "/" .. name .. "/dict.sqlite3", "mode") == "file" then
            if not opened_dictionaries[name] and not open_errors[name] then
                local dict, err = Dictionary.open(dir .. "/" .. name)
                if dict then
                    dict.folder = name
                    opened_dictionaries[name] = dict
                else
                    open_errors[name] = err
                    logger.warn("yomitan: cannot open dictionary", name, err)
                end
            end
            if opened_dictionaries[name] then
                table.insert(found, opened_dictionaries[name])
            end
        end
    end
    -- Order: saved order first, then new dictionaries by title.
    local rank = {}
    for i, folder in ipairs(self.settings.dicts_order) do rank[folder] = i end
    table.sort(found, function(a, b)
        local ra, rb = rank[a.folder] or math.huge, rank[b.folder] or math.huge
        if ra ~= rb then return ra < rb end
        return a.title < b.title
    end)
    self.all_dictionaries = found
end

function Yomitan:updateEnabledDictionaries()
    local enabled = {}
    for _, dict in ipairs(self.all_dictionaries) do
        if not self.settings.dicts_disabled[dict.folder] then
            table.insert(enabled, dict)
        end
    end
    self.dictionaries = enabled
    if self.translator then
        self.translator:setDictionaries(enabled)
    else
        self.translator = Translator.new{ dictionaries = enabled, json_decode = require("rapidjson").decode }
    end
    self.cache = nil
    self:updateRegistration()
end

function Yomitan:isActive()
    return self.dictionaries ~= nil and #self.dictionaries > 0
end

--- Take over Japanese selection and lookups while dictionaries are enabled.
function Yomitan:updateRegistration()
    local active = self:isActive()
    if self.ui and self.ui.dictionary and self.ui.dictionary.setLookupBackend then
        self.ui.dictionary:setLookupBackend(active and self or nil)
    end
    if active then
        -- LanguageSupport lets the first plugin that supports a language
        -- win, in no particular order, so the StarDict-based Japanese plugin
        -- must step aside. Plugins are initialised in path order, so it has
        -- already registered itself by now.
        if LanguageSupport.plugins["japanese"] then
            self.displaced_plugin = LanguageSupport.plugins["japanese"]
            LanguageSupport.plugins["japanese"] = nil
        end
        LanguageSupport:registerPlugin(self)
    else
        if LanguageSupport.plugins[self.name] == self then
            LanguageSupport.plugins[self.name] = nil
        end
        if self.displaced_plugin then
            LanguageSupport:registerPlugin(self.displaced_plugin)
            self.displaced_plugin = nil
        end
    end
end

--- Show Yomitan results in the compact popup (see yomitan/popup.lua).
-- Installed before Compat, whose showDict() wrapper must run first.
local function installPopupHook()
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if ReaderDictionary._yomitan_popup_hook then return end
    ReaderDictionary._yomitan_popup_hook = true
    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(rd, word, results, boxes, link, dict_close_callback)
        local backend = rd.lookup_backend
        if backend and backend.settings and backend.settings.mini_popup
                and results and results[1] and results[1].yomitan_short then
            return backend:showPopup(rd, word, results, boxes, link, dict_close_callback, orig_showDict)
        end
        return orig_showDict(rd, word, results, boxes, link, dict_close_callback)
    end
end

function Yomitan:showPopup(rd, word, results, boxes, link, dict_close_callback, show_full)
    rd:dismissLookupInfo()
    local Popup = require("yomitan/popup")
    local highlight = rd.highlight
    local opening_full = false
    Popup:new{
        refresh_type = self.settings.fast_refresh and "fast" or "ui",
        results = results,
        word_boxes = boxes,
        on_full = function(index)
            opening_full = true
            local full = {}
            for i, r in ipairs(results) do
                local copy = {}
                for k, v in pairs(r) do copy[k] = v end
                copy.definition, copy.is_html = fullDefinition(r), true
                full[i] = copy
            end
            show_full(rd, word, full, boxes, link, dict_close_callback)
            if index > 1 and rd.dict_window then
                rd.dict_window:changeDictionary(index)
            end
        end,
        on_close = function()
            if opening_full then return end
            if highlight then
                -- Like DictQuickLookup: keep the word highlighted for a moment.
                local clear_id = highlight:getClearId()
                UIManager:scheduleIn(G_defaults:readSetting("DELAY_CLEAR_HIGHLIGHT_S"), function()
                    highlight:clear(clear_id)
                end)
            end
            if dict_close_callback then dict_close_callback() end
        end,
        on_tap_outside = function(ges)
            -- Tapping another word looks it up straight away.
            if self.settings.tap_lookup and self.ui.highlight then
                self:onTapLookup(ges)
            end
        end,
    }:show()
end

function Yomitan:init()
    installPopupHook()
    -- Install the hooks ourselves on builds that do not provide them.
    Compat.install()
    self:readSettings()
    self:discoverDictionaries()
    self:updateEnabledDictionaries()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:addToggleButton()
end

function Yomitan:onReaderReady()
    self:setupTapLookup()
    -- Open the databases and run the lookup code once, so that the first
    -- real lookup is as quick as the following ones.
    UIManager:scheduleIn(1, function()
        if not self:isActive() then return end
        local ok, result = pcall(self.findTerms, self, "食べさせられた")
        if ok then pcall(self.buildResults, self, "", result.entries) end
        require("yomitan/popup")
    end)
end

--- Tap on Japanese text to look it up, like a long-press. Taps elsewhere,
-- and taps on links, highlights, menus and corners, work as before.
function Yomitan:setupTapLookup()
    local ui = self.ui
    if not (ui.rolling and ui.highlight and ui.touch_zone_dg and Device:isTouchDevice()) then return end
    ui:registerTouchZones({
        {
            id = "yomitan_tap_lookup",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            -- Text near the top and bottom edges is inside the menu zones:
            -- a tap on text looks it up, a tap on the margin opens the menu.
            overrides = { "tap_forward", "tap_backward",
                "readermenu_tap", "readermenu_ext_tap", "readerconfigmenu_tap", "readerconfigmenu_ext_tap" },
            handler = function(ges) return self:onTapLookup(ges) end,
        },
    })
    -- Let these zones go first.
    for _, id in ipairs({ "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode",
            "readerfooter_tap", "tap_top_left_corner", "tap_top_right_corner",
            "tap_left_bottom_corner", "tap_right_bottom_corner" }) do
        if ui._zones[id] then
            ui.touch_zone_dg:addNodeDep("yomitan_tap_lookup", id)
        end
    end
    ui._ordered_touch_zones = {}
    for _, zone_id in ipairs(ui.touch_zone_dg:serialize()) do
        table.insert(ui._ordered_touch_zones, ui._zones[zone_id])
    end
end

function Yomitan:onTapLookup(ges)
    if not (self.settings.tap_lookup and self:isActive()) then return end
    local highlight = self.ui.highlight
    if highlight.select_mode or highlight.hold_pos then return end
    local pos = self.ui.view:screenToPageTransform(ges.pos)
    if not pos then return end
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, pos, true)
    if not (ok and word and type(word.word) == "string" and Japanese.isStringPartiallyJapanese(word.word)) then
        return
    end
    -- crengine returns the nearest word even for taps on empty space:
    -- only accept taps on the word itself (with a little slack).
    local box, slack = word.sbox, Screen:scaleBySize(4)
    if not (box and pos.x >= box.x - slack and pos.x <= box.x + box.w + slack
            and pos.y >= box.y - slack and pos.y <= box.y + box.h + slack) then
        return
    end
    highlight:onHold(nil, ges)
    local selected = highlight.selected_text ~= nil
    highlight:onHoldRelease()
    return selected
end

--- A popup button switching between the short and the full entry.
function Yomitan:addToggleButton()
    local dictionary = self.ui and self.ui.dictionary
    self.can_toggle = dictionary and dictionary.addToDictButtons ~= nil
    if not self.can_toggle then return end
    dictionary:addToDictButtons{
        id = "yomitan_toggle_view",
        text = _("Full / short"),
        show_func = function(dql)
            local r = dql.results and dql.results[1]
            return r ~= nil and r.yomitan_short ~= nil
        end,
        callback = function(dql)
            local r = dql.results[dql.dict_index]
            if not (r and r.yomitan_short) then return end
            if r.is_html then
                r.definition, r.is_html = r.yomitan_short, false
            else
                r.definition, r.is_html = fullDefinition(r), true
            end
            dql:changeDictionary(dql.dict_index)
        end,
    }
end

function Yomitan:supportsLanguage(language_code)
    return language_code == "ja" or language_code == "jpn"
end

function Yomitan:findTerms(text)
    return self.translator:findTerms(text, {
        mode = self.settings.result_mode,
        -- Yomitan's "scanning.alphanumeric" option defaults to true, so
        -- non-Japanese characters are not stripped.
        remove_non_japanese = false,
    })
end

--- LanguageSupport hook: select the longest dictionary match starting at the
-- long-pressed character, like Yomitan highlights it.
function Yomitan:onWordSelection(args)
    if not self:isActive() then return end
    local callbacks = args.callbacks
    local text, end_positions = Scanner.scan(callbacks, args.pos0, self.settings.scan_length)
    if text == "" or not Japanese.isStringPartiallyJapanese(text) then
        return
    end
    local result = self:findTerms(text)
    logger.dbg("yomitan: scanned", text, "matched length", result.original_text_length, "entries", #result.entries)
    local length = result.original_text_length
    if length == 0 then
        return
    end
    local chars = {}
    for c in text:gmatch(util.UTF8_CHAR_PATTERN) do
        table.insert(chars, c)
        if #chars == length then break end
    end
    local selected = table.concat(chars)
    self.cache = { text = selected, result = result }
    self.last_selection = { pos0 = args.pos0, pos1 = end_positions[length], text = selected }
    return {args.pos0, end_positions[length], selected}
end

-- Public API, used by bookwords.koplugin

--- Term and reading of the top entry for `text` (the dictionary form of the
-- word a lookup of `text` shows first).
function Yomitan:getTopEntry(text)
    if not self:isActive() then return end
    local result
    if self.cache and self.cache.text == text then
        result = self.cache.result
    else
        result = self:findTerms(text)
        self.cache = { text = text, result = result } -- for the lookup that follows
    end
    local entry = result.entries[1]
    local headword = entry and entry.headwords[1]
    if headword then
        return headword.term, headword.reading
    end
end

--- What a lookup at the start of `text` would match, cheaply (glossaries are
-- not read). Returns the match length in characters and the {term, reading}
-- of the entries of that length.
function Yomitan:matchAt(text)
    if not self:isActive() then return end
    local result = self.translator:findTerms(text, {
        mode = self.settings.result_mode,
        remove_non_japanese = false,
        match_only = true,
    })
    local length = result.original_text_length
    if length == 0 then return end
    local words = {}
    for _, entry in ipairs(result.entries) do
        if entry.max_original_text_length == length then
            for _, headword in ipairs(entry.headwords) do
                table.insert(words, { term = headword.term, reading = headword.reading })
            end
        end
    end
    return length, words
end

-- Lookup backend (see ReaderDictionary:setLookupBackend)

--- The HTML entry of a result from buildResults(), built on first use.
fullDefinition = function(result)
    if not result.yomitan_full then
        result.yomitan_full = Html.entryForDictionary(result.yomitan_entry, result.dict)
    end
    return result.yomitan_full
end

function Yomitan:canLookup(word)
    return self:isActive() and type(word) == "string" and Japanese.isStringPartiallyJapanese(word)
end

--- Build DictQuickLookup results: one page per (entry, dictionary), in
-- Yomitan's sort order.
function Yomitan:buildResults(word, entries)
    local by_title = {}
    for _, dict in ipairs(self.dictionaries) do by_title[dict.title] = dict end
    local results = {}
    for _, entry in ipairs(entries) do
        local headword = Html.headwordText(entry)
        local seen = {}
        for _, definition in ipairs(entry.definitions) do
            local title = definition.dictionary
            if not seen[title] then
                seen[title] = true
                local dict = by_title[title]
                local result = {
                    dict = title,
                    word = headword,
                    css = Html.BASE_CSS .. (dict and dict.styles or ""),
                    dictionary_resource_directory = dict and dict.dir,
                    ifo_lang = { lang_in = "ja", lang_out = dict and dict.meta.targetLanguage },
                    yomitan_entry = entry,
                    yomitan_short = Text.entryForDictionary(entry, title),
                }
                if self.settings.mini_popup or (self.can_toggle and self.settings.short_view) then
                    -- Plain text shows up much faster than HTML, which is
                    -- only built when asked for (fullDefinition()).
                    result.definition, result.is_html = result.yomitan_short, false
                else
                    result.definition, result.is_html = fullDefinition(result), true
                end
                table.insert(results, result)
            end
        end
    end
    if #results == 0 then
        results[1] = {
            dict = _("Yomitan"),
            word = word,
            definition = _("No results."),
            no_result = true,
        }
    end
    return results
end

function Yomitan:lookup(word)
    local result
    if self.cache and self.cache.text == word then
        result = self.cache.result
    else
        result = self:findTerms(word)
    end
    return self:buildResults(word, result.entries)
end

-- Menu

function Yomitan:showDictionariesMenu(touchmenu_instance)
    local SortWidget = require("ui/widget/sortwidget")
    self:discoverDictionaries()
    local disabled = util.tableDeepCopy(self.settings.dicts_disabled)
    local items = {}
    for _, dict in ipairs(self.all_dictionaries) do
        table.insert(items, {
            text = dict.title,
            dict = dict,
            callback = function()
                disabled[dict.folder] = not disabled[dict.folder] or nil
            end,
            checked_func = function()
                return not disabled[dict.folder]
            end,
        })
    end
    UIManager:show(SortWidget:new{
        title = _("Manage Yomitan dictionaries"),
        item_table = items,
        callback = function()
            local order = {}
            for i, item in ipairs(items) do order[i] = item.dict.folder end
            self.settings.dicts_order = order
            self.settings.dicts_disabled = disabled
            self:saveSettings()
            self:discoverDictionaries()
            self:updateEnabledDictionaries()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function Yomitan:showInfo()
    local InfoMessage = require("ui/widget/infomessage")
    local lines = { T(_("Dictionary folder: %1"), self:getDataDir()), "" }
    if #self.all_dictionaries == 0 then
        table.insert(lines, _("No dictionaries found. Convert Yomitan .zip dictionaries with tools/yomitan_convert.py and copy the resulting folders here."))
    end
    for __, dict in ipairs(self.all_dictionaries) do
        table.insert(lines, T(_("%1 (rev. %2): %3 terms"), dict.title, dict.revision or "?", dict.meta.term_count or "?"))
    end
    for name, err in pairs(open_errors) do
        table.insert(lines, T(_("%1: %2"), name, err))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function Yomitan:addToMainMenu(menu_items)
    local modes = {
        { "group", _("Group by term and reading") },
        { "term", _("Group by term") },
        { "split", _("One entry per definition") },
    }
    local mode_items = {}
    for _, mode in ipairs(modes) do
        table.insert(mode_items, {
            text = mode[2],
            radio = true,
            checked_func = function() return self.settings.result_mode == mode[1] end,
            callback = function()
                self.settings.result_mode = mode[1]
                self.cache = nil
                self:saveSettings()
            end,
        })
    end
    menu_items.yomitan = {
        text = _("Yomitan dictionaries"),
        sorting_hint = "search_settings",
        sub_item_table = {
            {
                text_func = function()
                    local n = self.dictionaries and #self.dictionaries or 0
                    return T(_("Manage dictionaries: %1 enabled"), n)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showDictionariesMenu(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Scan length: %1 characters"), self.settings.scan_length)
                end,
                help_text = _("Maximum number of characters read from the long-pressed position when looking for the longest matching word."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Scan length"),
                        value = self.settings.scan_length,
                        value_min = 1,
                        value_max = 100,
                        default_value = DEFAULT_SCAN_LENGTH,
                        callback = function(spin)
                            self.settings.scan_length = spin.value
                            self:saveSettings()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("Result grouping"),
                sub_item_table = mode_items,
            },
            {
                text = _("Compact popup"),
                help_text = _("Show lookups in a small popup with short definitions, which opens faster. Its \"Full\" button opens the regular dictionary window."),
                checked_func = function() return self.settings.mini_popup end,
                callback = function()
                    self.settings.mini_popup = not self.settings.mini_popup
                    self:saveSettings()
                end,
            },
            {
                text = _("Fast popup refresh"),
                help_text = _("Draw the compact popup with the fastest black-and-white e-ink refresh. Text edges look slightly rougher and faint ghosting may remain until the next full refresh."),
                enabled_func = function() return self.settings.mini_popup end,
                checked_func = function() return self.settings.fast_refresh end,
                callback = function()
                    self.settings.fast_refresh = not self.settings.fast_refresh
                    self:saveSettings()
                end,
            },
            {
                text = _("Tap to look up"),
                help_text = _("Tap on Japanese text to look it up, as with a long-press. Swipe to turn pages; taps where there is no Japanese text still turn pages."),
                checked_func = function() return self.settings.tap_lookup end,
                callback = function()
                    self.settings.tap_lookup = not self.settings.tap_lookup
                    self:saveSettings()
                end,
            },
            {
                text = _("Short definitions first"),
                help_text = _("Show definitions as plain text without examples and images, which appears faster. The \"Full / short\" button in the popup switches to the full entry."),
                enabled_func = function() return self.can_toggle end,
                checked_func = function() return self.settings.short_view end,
                callback = function()
                    self.settings.short_view = not self.settings.short_view
                    self:saveSettings()
                end,
            },
            {
                text = _("Open and close popup without flashing"),
                help_text = _("Uses a faster refresh for the dictionary popup instead of a flashing one. Some ghosting may remain until the next page turn."),
                checked_func = function() return self.settings.no_flash end,
                callback = function()
                    self.settings.no_flash = not self.settings.no_flash
                    Compat.no_flash = self.settings.no_flash
                    self:saveSettings()
                end,
            },
            {
                text = _("Dictionary information"),
                keep_menu_open = true,
                callback = function() self:showInfo() end,
            },
        },
    }
end

return Yomitan
