# Line breaking demo

Reference implementation, in JavaScript, of the behaviour specified in
`doc/Japanese_line_breaking.md`. It renders the same text in vertical columns
with several line breaking methods side by side. Panel 7, "Keep Yomitan words
+ particles", is the chosen behaviour.

It is a development aid only: nothing here ships with KOReader.

## What to port from where

| Plan component | Reference code |
|---|---|
| `JpDeinflector` | `makeYomitan()` → `deinflect()` in `yomitan-mini.js`, itself a port of `plugins/yomitan.koplugin/yomitan/language_transformer.lua` |
| Word list lookup and flags | `makeYomitan()` → `lookup()`, `make_words.py` |
| Best-path segmentation | `ymBestPath()`, `ymSegment()` in `yomitan-mini.js` |
| Units | `ymUnits()` in `yomitan-mini.js` |
| Break scoring | `splitCost()`, `gain()`, `BREAK.keep()` in `page.src.html` |
| Kinsoku and JLReq squeeze-in (simplified model) | `BREAK.jis()`, `breakable()`, `gap()`, `shrinkable()` in `page.src.html` |

The page's layout model is simplified: every character is 1 em, punctuation
is ½ em plus ½ em of space. crengine uses real advances and JFM glue instead.

## Build

The generated files (`words.txt`, `transforms.json`, `budoux.mjs`,
`linebreak_demo.html`, `logic_check.js`) are not committed.

```sh
cd tools/linebreak_demo
python3 make_words.py "<path>/[Bilingual] JMdict (Recommended).zip"
luajit dump.lua ../../plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua > transforms.json
curl -o budoux.mjs https://cdn.jsdelivr.net/npm/budoux@0.7.0/+esm
python3 build.py      # -> linebreak_demo.html (about 10 MB, works offline)
node logic_check.js   # columns, kinsoku violations, bad splits and loosest column per method
```

`samples.json` holds public-domain excerpts (夏目漱石, 芥川龍之介, 太宰治).
`phrases.json` is their BudouX segmentation.
