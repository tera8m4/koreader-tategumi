# Yomitan spec fixtures

Used by `spec/unit/yomitan_spec.lua` and `spec/unit/yomitan_plugin_spec.lua`,
except where noted.

- `transform_cases.lua`, `translator_cases.lua`: generated from Yomitan's
  `test/language/japanese-transforms.test.js` and
  `test/data/translator-test-{inputs,results}.json` by
  `tools/yomitan/generate_lua_data.mjs`.
- `jpwords_dictionary/`: the JMdict entries whose expression or reading the
  sentences of `spec/unit/jpwords_spec.lua` and
  `spec/unit/vertical_keep_words_spec.lua` can match, with their definitions
  left out, converted with `tools/yomitan_convert.py`. Used by those specs;
  it segments these sentences exactly as the full JMdict does. JMdict is the
  property of the Electronic Dictionary Research and Development Group, used
  under its licence (CC BY-SA 4.0).
- `test_dictionary/`: Yomitan's `test/data/dictionaries/valid-dictionary1`
  converted with `tools/yomitan_convert.py`, so that row ids match the ids in
  Yomitan's expected results.

Yomitan and its test data are licensed under the GNU GPL v3 or later.
