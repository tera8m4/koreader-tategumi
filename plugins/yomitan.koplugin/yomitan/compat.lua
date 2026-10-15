--[[--
Hooks for KOReader builds that lack the ones the plugin needs.

This repository adds ReaderDictionary:setLookupBackend() and a selected-text
override to LanguageSupport's onWordSelection. On other builds (upstream
KOReader, or an older build of this fork) the plugin installs equivalent
hooks itself, so that it can be installed by copying just its folder.

@module yomitan.compat
]]

local Compat = {}

--- ReaderDictionary: route lookups to the backend, keeping the original
-- bookkeeping (lookup history, WordLookedUp, external dictionary apps, the
-- lookup progress message) and only replacing the sdcv lookup.
local function patchReaderDictionary()
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if ReaderDictionary.setLookupBackend then
        return -- native support
    end

    function ReaderDictionary:setLookupBackend(backend)
        self.lookup_backend = backend
    end

    local orig_stardictLookup = ReaderDictionary.stardictLookup
    ReaderDictionary.stardictLookup = function(self, word, dict_names, fuzzy_search, boxes, link, dict_close_callback)
        local backend = self.lookup_backend
        if not (backend and backend:canLookup(word)) then
            return orig_stardictLookup(self, word, dict_names, fuzzy_search, boxes, link, dict_close_callback)
        end
        self._yomitan_word = word
        -- A non-empty dictionary list, or the lookup would stop before
        -- startSdcv() when no StarDict dictionary is enabled.
        local ok, err = pcall(orig_stardictLookup, self, word, { "Yomitan" }, false, boxes, link, dict_close_callback)
        self._yomitan_word = nil
        self._yomitan_results = nil
        if not ok then error(err, 0) end
    end

    local orig_startSdcv = ReaderDictionary.startSdcv
    ReaderDictionary.startSdcv = function(self, word, dict_names, fuzzy_search)
        if not self._yomitan_word then
            return orig_startSdcv(self, word, dict_names, fuzzy_search)
        end
        self._yomitan_word = nil
        local results = self.lookup_backend:lookup(word)
        -- stardictLookup() passes the results through tidyMarkup(), which
        -- strips the HTML of dictionaries it does not know: give it
        -- placeholders, and put the real results back in showDict().
        self._yomitan_results = results
        local placeholders = {}
        for i, r in ipairs(results) do
            placeholders[i] = { dict = r.dict, word = r.word, definition = "" }
        end
        return placeholders
    end

    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(self, word, results, ...)
        if self._yomitan_results then
            results = self._yomitan_results
            self._yomitan_results = nil
        end
        return orig_showDict(self, word, results, ...)
    end
end

--- LanguageSupport: use the text returned by the plugin (without ruby
-- annotations) as the selected text. Harmless where this is native.
local function patchLanguageSupport()
    local LanguageSupport = require("languagesupport")
    if LanguageSupport._yomitan_text_override then
        return
    end
    LanguageSupport._yomitan_text_override = true
    local orig_improveWordSelection = LanguageSupport.improveWordSelection
    LanguageSupport.improveWordSelection = function(self, selection)
        local result = orig_improveWordSelection(self, selection)
        local plugin = self.plugins and self.plugins.yomitan
        local last = plugin and plugin.last_selection
        if result and last and last.pos0 == result.pos0 and last.pos1 == result.pos1 then
            result.text = last.text
        end
        return result
    end
end

function Compat.install()
    patchReaderDictionary()
    patchLanguageSupport()
end

return Compat
