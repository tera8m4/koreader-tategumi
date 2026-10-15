# Yomitan dictionaries for KOReader

Japanese dictionary lookups that behave like
[Yomitan](https://github.com/yomidevs/yomitan), using Yomitan dictionaries.

- **Scanning**: long-pressing a character reads up to 16 characters from it
  (configurable) and selects the longest text that matches a dictionary entry
  after Yomitan's text preprocessing and deinflection. Ruby annotations
  (furigana) are skipped while scanning.
- **Lookup**: every match, including shorter ones, is shown in Yomitan's
  order, with the inflection chain (e.g. `-て « -いる « -ます « negative « -た`),
  tags and rich structured-content definitions with images. Links to other
  entries can be tapped.
- While at least one Yomitan dictionary is enabled, it replaces StarDict
  lookups for Japanese text and the StarDict-based `japanese.koplugin`
  selection. Non-Japanese words still use StarDict.

## Installing dictionaries

Conversion happens on a computer, with Python 3 (standard library only):

```sh
python3 tools/yomitan_convert.py -o out/ jitendex-yomitan.zip other-dictionary.zip
```

Copy each resulting folder from `out/` to `koreader/data/yomitan/` on the
device, then enable and order them in
*Search settings → Yomitan dictionaries → Manage dictionaries*.

Optionally install [Pillow](https://pypi.org/project/pillow/) before
converting: images in formats KOReader cannot display (AVIF, WebP, …) are
then re-encoded as JPEG or PNG. Without Pillow they are kept and reported.

Supported: term banks (format 1 and 3), tag banks, structured content, images,
dictionary-provided deinflections and `styles.css`. Frequency, pitch accent,
IPA and kanji banks are skipped.

## Layout

| File | Origin |
| --- | --- |
| `yomitan/language_transformer.lua` | `ext/js/language/language-transformer.js` |
| `yomitan/japanese.lua` | `ext/js/language/ja/japanese*.js`, `ext/js/language/CJK-util.js` |
| `yomitan/translator.lua` | `ext/js/language/translator.js` (term lookup) |
| `yomitan/html.lua` | `ext/js/display/structured-content-generator.js` |
| `yomitan/data/*.lua` | generated from Yomitan by `tools/yomitan/generate_lua_data.mjs` |
| `yomitan/db.lua` | reads the databases written by `tools/yomitan_convert.py` |
| `yomitan/scanner.lua` | KOReader-specific text scanning |

The generated data and the specs (`spec/unit/yomitan_spec.lua`) come from the
same Yomitan revision; to update, run the generator against a newer Yomitan
checkout (see the header of `tools/yomitan/generate_lua_data.mjs`).

## Differences from Yomitan

- Lengths are counted in Unicode code points rather than UTF-16 code units,
  and the final alphabetical tie-break uses byte order instead of
  `Intl.Collator`.
- Only the "group", "term" and "split" result modes exist; "merge" mode,
  frequency sorting, text replacements and primary readings are not ported.
- MuPDF, which renders the definitions, has no ruby layout and no
  `<details>`: readings are shown in small text after their base, and
  `<details>` blocks are always expanded. Collapsed images are shown inline.
- No audio, Anki export or kanji lookups.

## License

The ported code and the generated data are derived from Yomitan and, like
KOReader, licensed under the GNU GPL v3 or later. The kanji variant table comes
from the MIT-licensed [kanji-processor](https://www.npmjs.com/package/kanji-processor)
package.
