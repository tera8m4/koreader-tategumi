# Yomitan spec fixtures

Used by `spec/unit/yomitan_spec.lua` and `spec/unit/yomitan_plugin_spec.lua`.

- `transform_cases.lua`, `translator_cases.lua`: generated from Yomitan's
  `test/language/japanese-transforms.test.js` and
  `test/data/translator-test-{inputs,results}.json` by
  `tools/yomitan/generate_lua_data.mjs`.
- `test_dictionary/`: Yomitan's `test/data/dictionaries/valid-dictionary1`
  converted with `tools/yomitan_convert.py`, so that row ids match the ids in
  Yomitan's expected results.

Yomitan and its test data are licensed under the GNU GPL v3 or later.
