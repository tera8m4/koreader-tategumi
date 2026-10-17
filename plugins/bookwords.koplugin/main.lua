--[[--
Looked-up words: remembers the words looked up in each book and marks them
where they appear again in that book (crengine documents only).

With the Yomitan plugin active, words are recorded in dictionary form and
matched with Yomitan's deinflection, so looking up 食べる also marks 食べた.

@module koplugin.bookwords
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local Marker = require("bookwords/marker")
local Menu = require("ui/widget/menu")
local Store = require("bookwords/store")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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

function BookWords:onWordLookedUp(word)
    if not self.store or self.suppress_recording or type(word) ~= "string" or word == "" then return end
    local term, reading
    local yomitan = self.ui.yomitan
    if yomitan and yomitan.getTopEntry then
        term, reading = yomitan:getTopEntry(word)
    end
    self.store:add(term or word, reading or "", word)
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
        local InfoMessage = require("ui/widget/infomessage")
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
        },
    }
end

return BookWords
