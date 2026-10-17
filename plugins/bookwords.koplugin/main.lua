--[[--
Looked-up words: remembers the words looked up in each book and marks them
where they appear again in that book (crengine documents only).

With the Yomitan plugin active, words are recorded in dictionary form and
matched with Yomitan's deinflection, so looking up 食べる also marks 食べた.

@module koplugin.bookwords
]]

local Anki = require("bookwords/anki")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Marker = require("bookwords/marker")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Store = require("bookwords/store")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local SETTINGS_KEY = "bookwords_settings"

local BookWords = WidgetContainer:extend{
    name = "bookwords",
    is_doc_only = true,
}

function BookWords:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    if self.settings.mark == nil then self.settings.mark = true end
    if self.settings.furigana == nil then self.settings.furigana = true end
    self.ui.menu:registerToMainMenu(self)
end

function BookWords:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function BookWords:onReaderReady()
    if not self.ui.rolling then return end -- needs crengine text positions
    self.store = Store.load(self.ui.doc_settings)
    self.marker = Marker.new(self)
    self.ui.view:registerViewModule("bookwords", self.marker)
end

local SENTENCE_END = { ["。"] = true, ["！"] = true, ["？"] = true, ["!"] = true, ["?"] = true, ["\n"] = true }
local CLOSING = { ["」"] = true, ["』"] = true, ["）"] = true, [")"] = true, ["】"] = true, ["”"] = true }
local SPACE = { [" "] = true, ["\t"] = true, ["\n"] = true, ["　"] = true }
local MAX_CONTEXT_CHARS = 120 -- on each side of the word

local function chars(s)
    local t = {}
    for c in (s or ""):gmatch(util.UTF8_CHAR_PATTERN) do table.insert(t, c) end
    return t
end

--- The sentence around the selected word, if the lookup was of the selection.
function BookWords:selectedSentence(word)
    local highlight = self.ui.highlight
    if not (highlight and highlight.selected_text and highlight.selected_text.text == word) then return end
    local prev, next = highlight:getSelectedWordContext(30)
    if not prev then return end
    local before, after = chars(prev), chars(next)
    local first = #before + 1
    while first > 1 and #before - first < MAX_CONTEXT_CHARS and not SENTENCE_END[before[first - 1]] do
        first = first - 1
    end
    -- The closing bracket of the previous sentence, and indentation.
    while CLOSING[before[first]] or SPACE[before[first]] do first = first + 1 end
    local last = 0
    while last < #after and last < MAX_CONTEXT_CHARS and not SENTENCE_END[after[last + 1]] do
        last = last + 1
    end
    if SENTENCE_END[after[last + 1]] and after[last + 1] ~= "\n" then
        last = last + 1
        while CLOSING[after[last + 1]] do last = last + 1 end
    end
    return table.concat(before, "", first, #before) .. word .. table.concat(after, "", 1, last)
end

function BookWords:onWordLookedUp(word)
    if not self.store or self.suppress_recording or type(word) ~= "string" or word == "" then return end
    local term, reading
    local yomitan = self.ui.yomitan
    if yomitan and yomitan.getTopEntry then
        term, reading = yomitan:getTopEntry(word)
    end
    self.store:add(term or word, reading or "", word, self:selectedSentence(word))
end

function BookWords:onSaveSettings()
    if self.store then
        self.store:save(self.ui.doc_settings)
    end
end

function BookWords:onCloseDocument()
    if self.marker then self.marker:free() end
end

function BookWords:refreshPage()
    if self.marker then self.marker:invalidate() end
    UIManager:setDirty(self.ui.dialog, "ui")
end

local function wordText(word)
    if word.reading ~= "" and word.reading ~= word.term then
        return word.term .. "【" .. word.reading .. "】"
    end
    return word.term
end

function BookWords:_listItems()
    local items = {}
    for _, word in ipairs(self.store:list()) do
        table.insert(items, {
            text = wordText(word),
            mandatory = "×" .. word.count,
            word = word,
        })
    end
    return items
end

function BookWords:showList()
    if not self.store or self.store:isEmpty() then
        UIManager:show(InfoMessage:new{ text = _("No words looked up in this book yet.") })
        return
    end
    local menu
    menu = Menu:new{
        title = T(_("Looked-up words (%1)"), #self.store:list()),
        subtitle = _("Tap to look up, long-press to forget"),
        item_table = self:_listItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            UIManager:show(ConfirmBox:new{
                text = _("Forget all the words looked up in this book?"),
                ok_text = _("Forget all"),
                ok_callback = function()
                    self.store:clear()
                    UIManager:close(menu)
                    self:refreshPage()
                end,
            })
        end,
        onMenuSelect = function(menu_self, item)
            UIManager:close(menu)
            -- Looking a word up from the list does not count as a lookup.
            self.suppress_recording = true
            self.ui:handleEvent(Event:new("LookupWord", item.word.term))
            self.suppress_recording = false
            return true
        end,
        onMenuHold = function(menu_self, item)
            UIManager:show(ConfirmBox:new{
                text = T(_("Forget %1?"), item.text),
                ok_text = _("Forget"),
                ok_callback = function()
                    self.store:remove(item.word.key)
                    if self.store:isEmpty() then
                        UIManager:close(menu)
                    else
                        menu:switchItemTable(T(_("Looked-up words (%1)"), #self.store:list()), self:_listItems(), -1)
                    end
                    self:refreshPage()
                end,
            })
            return true
        end,
    }
    UIManager:show(menu)
end

function BookWords:sendToAnki()
    if not self.settings.anki_url then
        UIManager:show(InfoMessage:new{ text = _("Set the AnkiConnect address first.") })
        return
    end
    if #self.store:unsent() == 0 then
        UIManager:show(InfoMessage:new{ text = _("All the words looked up in this book are already in Anki.") })
        return
    end
    NetworkMgr:runWhenOnline(function() self:_sendToAnki() end)
end

function BookWords:_sendToAnki()
    local unsent = self.store:unsent()
    local info = InfoMessage:new{ text = T(_("Sending %1 words to Anki…"), #unsent) }
    UIManager:show(info)
    UIManager:forceRePaint()
    local yomitan = self.ui.yomitan
    local book = self.ui.doc_props and self.ui.doc_props.display_title
    local words = {}
    for i, item in ipairs(unsent) do
        local word = item.word
        words[i] = {
            term = word.term,
            reading = word.reading,
            sentence = word.sentence,
            sentence_word = word.sentence_word,
            definition = yomitan and yomitan.getDefinition and yomitan:getDefinition(word.term, word.reading),
            book = book,
        }
    end
    local in_anki, added = Anki.addWords(self.settings.anki_url, self.settings.anki_deck or Anki.DEFAULT_DECK, words)
    UIManager:close(info)
    if not in_anki then
        UIManager:show(InfoMessage:new{ text = T(_("Could not send the words to Anki:\n%1"), added) })
        return
    end
    for i, item in ipairs(unsent) do
        if in_anki[i] then self.store:markSent(item.key) end
    end
    self.store:save(self.ui.doc_settings)
    UIManager:show(InfoMessage:new{
        text = T(_("Added %1 notes to Anki.\n%2 words were already in the deck."), added, #unsent - added),
    })
end

function BookWords:editAnkiSetting(key, title, hint, normalize, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.settings[key] or "",
        input_hint = hint,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = util.trim(dialog:getInputText())
                    if normalize then value = normalize(value) end
                    self.settings[key] = value ~= "" and value or nil
                    self:saveSettings()
                    UIManager:close(dialog)
                    touchmenu_instance:updateItems()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookWords:addToMainMenu(menu_items)
    menu_items.bookwords = {
        text = _("Looked-up words"),
        sub_item_table = {
            {
                text = _("Words looked up in this book"),
                enabled_func = function() return self.store ~= nil end,
                callback = function() self:showList() end,
            },
            {
                text = _("Mark looked-up words"),
                help_text = _("Underline words already looked up in this book wherever they appear (a line beside the column in vertical text)."),
                checked_func = function() return self.settings.mark end,
                callback = function()
                    self.settings.mark = not self.settings.mark
                    self:saveSettings()
                    self:refreshPage()
                end,
            },
            {
                text = _("Show furigana for looked-up words"),
                help_text = _("Show the reading beside marked words that contain kanji and have no furigana in the book. Needs enough line spacing."),
                enabled_func = function() return self.settings.mark end,
                checked_func = function() return self.settings.furigana end,
                callback = function()
                    self.settings.furigana = not self.settings.furigana
                    self:saveSettings()
                    self:refreshPage()
                end,
            },
            {
                text = _("Anki"),
                sub_item_table = {
                    {
                        text = _("Send words to Anki"),
                        help_text = _("Add the words looked up in this book that were not sent yet to Anki, with their sentence and definition. Needs Anki running with the AnkiConnect add-on on a computer on the same network."),
                        enabled_func = function() return self.store ~= nil end,
                        callback = function() self:sendToAnki() end,
                    },
                    {
                        text_func = function()
                            return T(_("AnkiConnect address: %1"), self.settings.anki_url or _("not set"))
                        end,
                        help_text = _("The address of the computer running Anki, e.g. 192.168.1.5. In AnkiConnect's config, set webBindAddress to 0.0.0.0 so that it accepts connections from the network."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:editAnkiSetting("anki_url", _("AnkiConnect address"), "192.168.1.5:8765",
                                function(value) return Anki.normalizeUrl(value) or "" end, touchmenu_instance)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Deck: %1"), self.settings.anki_deck or Anki.DEFAULT_DECK)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:editAnkiSetting("anki_deck", _("Anki deck"), Anki.DEFAULT_DECK, nil, touchmenu_instance)
                        end,
                    },
                },
            },
        },
    }
end

return BookWords
