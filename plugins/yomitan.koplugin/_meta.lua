local _ = require("gettext")
return {
    fullname = _("Yomitan dictionaries"),
    description = _([[
Japanese dictionary lookups that work like Yomitan: long-press a word to select the longest dictionary match (with deinflection, kana and width variants, and furigana skipped), and see every matching entry with its inflection chain and rich definitions.

Dictionaries are Yomitan .zip files converted on a computer with tools/yomitan_convert.py and copied to koreader/data/yomitan/. While any are enabled, they replace StarDict dictionaries for Japanese text.]]),
}
