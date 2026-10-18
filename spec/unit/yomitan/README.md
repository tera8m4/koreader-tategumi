# Yomitan spec fixtures

Used by `spec/unit/yomitan_spec.lua` and `spec/unit/yomitan_plugin_spec.lua`,
except where noted.

- `transform_cases.lua`, `translator_cases.lua`: generated from Yomitan's
  `test/language/japanese-transforms.test.js` and
  `test/data/translator-test-{inputs,results}.json` by
  `tools/yomitan/generate_lua_data.mjs`.
- `jpwords.tsv`: the keys of a word list built from JMdict (as
  `yomitan/wordlist.lua` builds it) that the sentences of
  `spec/unit/jpwords_spec.lua` and `spec/unit/vertical_keep_words_spec.lua`
  can match. Used by those specs.
- `test_dictionary/`: Yomitan's `test/data/dictionaries/valid-dictionary1`
  converted with `tools/yomitan_convert.py`, so that row ids match the ids in
  Yomitan's expected results.

Yomitan and its test data are licensed under the GNU GPL v3 or later.
