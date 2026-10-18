# Japanese line breaking: keep words together

Plan for avoiding badly split words at column breaks in vertical Japanese
text: 沈めてい|く, 飛び降|りる, a lone particle at the top of a column. The plan
also adds JLReq line adjustment, which absorbs the space that moving a break
costs.

The chosen behaviour is **"Keep Yomitan words + particles"** from the line
breaking demo (panel 7). Section [Behaviour](#behaviour) specifies it
completely, so this document does not depend on the demo.

Line references are to the commits pinned at the time of writing:
koreader `0251ba442`, koreader-base `b36c1dcd`, crengine `8477d5f4`.

## Start here (implementation handoff)

**Repository state:**

- **Branches:** all three repositories are checked out on branch
  `ja-keep-words`: `.`, `base`, and `base/thirdparty/kpvcrlib/crengine`.
  Other base submodules are not checked out.
- **Remotes in each submodule:**
  - `origin` and `tera8m4` point at the tera8m4 fork.
  - `m-tky` is fetch-only; its push URL is disabled.
- **Push rule:** push only to `tera8m4/` repositories (see
  [Repositories and pushing](#repositories-and-pushing)). Pushing starts CI,
  which is the only full build available, so ask the user before the first
  push.
- **Reference code:** `tools/linebreak_demo/` holds a JavaScript reference
  implementation of everything in [Behaviour](#behaviour). Its README maps
  each plan component to a function. Run `node logic_check.js` there to see
  the expected statistics.

**Machine:** Windows 11, with Git Bash and PowerShell.

- Available: `luajit`, `clang++` (LLVM), `node`, `python`.
- Not available: Nix, WSL. Docker must not be used.
- Consequence: KOReader cannot be built or its Busted specs run locally.
  - Keep the `JpDeinflector` / `JpWords` core free of crengine types (use
    `std::u32string`, with thin adapters for `lString32`). It can then be
    compiled and tested on its own with `clang++`, against
    `spec/unit/yomitan/transform_cases.lua` and the demo's results.
  - The full build and specs run in CI.
- Work phase by phase (see [Phases](#phases)). Start with phase 1, or with
  phase 2's standalone C++ core.

## Terms

- **Line breaking** (改行処理): choosing where a line ends. In vertical text a
  line is a column.
- **Kinsoku** (禁則処理): characters that may not start a line (、。」ー small
  kana…) or end one (「（…).
- **Line adjustment** (行の調整処理, JIS X 4051 / JLReq §3.8): fitting a line to
  its length.
  - **Squeeze in** (追い込み): shrink punctuation spacing so more text fits.
  - **Push out** (追い出し): move characters to the next line and stretch this
    one.
  - **Hanging** (ぶら下げ): let 、。 overflow the line end.
- **Word split** (泣き別れ): a word broken across two lines. The feature is
  *keep words together* (泣き別れ防止).
- **Unit**: a dictionary word plus the short particles, auxiliaries and copula
  that follow it (事が, 来たかも, 救うのだ). Breaks between units are free;
  breaks inside a unit have a cost (see [Behaviour](#behaviour)).

## Why these components

| Component | Question it answers | Why it is needed |
|---|---|---|
| **JLReq / JIS X 4051 line adjustment** | How do we pay for a moved break? | Moving a break back leaves a short column, which gets stretched. Squeezing first keeps columns tighter. It also improves layout on its own. |
| **Yomitan dictionaries + deinflection** | Where do words end? | libunibreak (UAX #14) allows a break between any two kana, so the engine knows nothing about words. The dictionaries the user already installs, plus Yomitan's deinflection rules, give word ends including inflections: 沈めて·いく, 飛び降りる, 抜かした·事·が. The algorithm is ported to C++ once and the Lua plugin calls it, so there is no duplicate implementation. |
| **Best-path segmentation** (new, not in Yomitan) | Which split of a whole sentence into words is right? | Yomitan's lookup takes the longest match from a tapped character. Used to split whole sentences it reproduces the bug: it reads 沈めてい as a form of 沈めている and leaves く alone. The demo showed that choosing the cheapest sequence of words fixes this (see [Segmentation](#segmentation)). |

BudouX (phrase model) was evaluated and is not used. It gives coarser units
than words + particles, with looser columns, and it gets some splits wrong
(一週|間ほど). Without Yomitan dictionaries, keep-words is off and layout is
exactly today's.

## Behaviour

### Segmentation

The input is one paragraph. The output is a list of words, each with flags.

1. Split the paragraph into runs at punctuation and spaces. Opening brackets
   attach to the next word. Closing marks (」』）、。・！？…) attach to the
   previous word.
2. For each run, choose the cheapest path through the run, by dynamic
   programming over positions. Candidate edges are substrings of 1–16
   characters:
   - **A dictionary match.** Deinflect the substring with the Yomitan rules.
     A result matches when its text is a key of the dictionaries and its conditions
     are 0 or share a flag with the entry's part-of-speech flags (exactly
     Yomitan's `conditionsMatch`). When several results match, prefer an
     entry that is both common and written this way (flags `c` and `w`
     below).
     - Cost 1 for a common word, with kanji or written this way in kana.
     - Cost 1.2 for any other word containing kanji.
     - Cost 2.5 for any other kana-only match. Obscure kana entries (くと)
       and kana spellings of kanji words (たから for 宝) are the usual false
       matches.
   - **An unknown katakana run** of 2+ characters: cost 2 (names and
     loanwords such as メロス).
   - **An unknown single character:** cost 3.5.
3. Entries tagged only `exp` (idioms such as 腰を抜かす) are skipped by default,
   so they split into their words.

### Word flags

The flags come from the dictionary database (`terms` table).

| Flag | Meaning | Source |
|---|---|---|
| `p` | particle / auxiliary / copula | `definition_tags` of an entry with this expression contains `prt`, `aux`, `aux-v`, `aux-adj` or `cop` |
| `x` | idiom only | every entry with this expression has `exp` |
| `c` | common | `term_tags` contains ⭐ (JMdict priority) |
| `w` | written this way | the key is an expression, or the reading of an entry tagged `uk` |

Plus the part-of-speech condition flags, from `rules` through the
deinflector's dictionary-form conditions.

### Units

A word with `p` and at most 2 letters (が, を, かも, だ), or an unknown single
kana, joins the unit before it. Longer particles and auxiliaries (ばかり,
している) start their own unit, so a column may start with them.

### Choosing a break (per column)

Start from the break that today's code chooses, after fill, hanging, wrap
decision and the kinsoku cascade. If it lies inside a unit, score every
candidate and take the cheapest. Each candidate's cost is its **split cost**
plus the **gain**: the em of space the column has to absorb to fill its
length.

Split cost of a break at position `k`:

| Break | Cost | Example |
|---|---|---|
| Between units | 0 | 腰を\|抜かした |
| Inside a unit, right before a kanji | 1.5 | 飛び\|降りる |
| Inside a unit, at a word boundary | 3 | 無闇を\|したと |
| Inside a word before kana (okurigana, inflection) | 8 | 飛び降\|りる |
| Fewer than `MIN` letters on either side | 20 | 沈めてい\|く, 救うの\|だ。」と |

The letters on each side of the break are counted within the unit, stopping
at punctuation. `MIN` defaults to 2.

The candidates are:

- the current break (cost + gain)
- **squeeze in** the rest of the unit, plus the characters kinsoku glues to it
  (。」). This is allowed only if the overflow fits within the column's
  shrinkable spacing. Cost 0.3 + the split cost of the new break.
- every earlier break allowed by kinsoku, down to the column start (cost +
  gain)

Results of the demo on three public-domain texts at column lengths 8–18:

- **Bad splits** (cost ≥ 8): today 6–16 per text, with this rule 0.
- **Loosest column:** today +0–1.5 em, with this rule +2–5 em.

The weights (1 per em of gain, 8 for okurigana) are the tuning knobs if
columns are too loose.

## Current code (what we hook into)

crengine, `crengine/src/lvtextfm_vert.cpp` (fork-only file, `#include`d at
the end of `lvtextfm.cpp:7665`):

- `processParagraphVertical` (1177) runs one loop iteration per column:
  - break test `y + fit.used > maxHeight` (1368)
  - wrap decision (1524)
  - burasagari second chance (1565)
  - kinsoku cascade (1612–1646)
  - `addLineVertical` (1715)
- Column fill estimate: `getVerticalColumnFitChar` (541) and
  `addVerticalColumnFitChar` (579).
- Justification post-pass, which already supports shrinking by priority:
  - `collectVerticalJustifyGaps` (678) provides `shrink_px` and
    `shrink_priority` from the JFM glue spec
  - `distributeVerticalJustifyByPriority` (606)
  - `applyVerticalJustification` (715)
- Render cache hash: `lvtinydom.cpp:484`.
- Precedent for a word file that affects layout: `UserHyphDict`
  (`include/hyphman.h:179`), loaded by `cre.setUserHyphenationDict`
  (`base/cre.cpp:548`, registered at 4728) and driven from
  `frontend/apps/reader/modules/readeruserhyph.lua`.

koreader:

- Deinflection: `plugins/yomitan.koplugin/yomitan/language_transformer.lua`.
  Its rules are in `yomitan/data/transforms_ja.lua`, generated by
  `tools/yomitan/generate_lua_data.mjs`.
- Startup order: plugins are created at `readerui.lua:472`; the document
  renders later in a post-init callback (`readerui.lua:344`).

## Design

### crengine: new fork-only files `include/jpwords.h`, `src/jpwords.cpp`

- **`JpDeinflector`**: a port of `language_transformer.lua`.
  - Same breadth-first expansion, condition flags and result order.
  - Results are `{text, conditions, parent, transform, rule}`; the trace is
    rebuilt from the parent links, and the cycle check walks the same chain.
  - Rules are loaded at runtime from the Lua descriptor, so
    `transforms_ja.lua` stays the single source of rule data.
- **`JpDictionary`** (interface): returns the `terms` rows of a key, or of
  every key with a given prefix. koreader-base implements it over the Yomitan
  plugin's databases, so there is no separate word list.
  - crengine works out the [word flags](#word-flags) from the rows (rows
    tagged `forms` do not count).
  - It fetches keys by their first three characters: deinflection only
    rewrites the end of a word, so one query answers every candidate with
    that prefix. Keys of one or two characters are queried exactly.
  - The fetched keys stay in an LRU cache of up to 50 000 keys (a few MB).
  - `getHash()` identifies the databases (paths, sizes, mtimes), for the
    render hash.
- **`JpWords`** (static facade):
  - `setMinKeep(int)`: 0 means off.
  - `segment(text, from, to)`: best-path segmentation and units for a window.
  - `splitCost(k)`: the cost table above.
  - Cache: per paragraph, keyed by window.

### crengine: hooks

- **`lvtextfm_vert.cpp` (fork file):**
  - Move the kinsoku cascade into a helper,
    `applyVerticalKinsokuCascade(fmt, pos, &wrapPos, &endp)`.
  - Add `adjustVerticalBreakForWords(...)`, called after the cascade and
    before `addLineVertical`. It does the candidate scoring.
    - The gain comes from the fill estimate helpers.
    - The available shrink comes from the same JFM glue values that
      `collectVerticalJustifyGaps` uses.
    - It re-runs the kinsoku cascade on the chosen break.
    - It never goes below `pos + 1`.
    - It skips mandatory wraps, `::first-line` clones and objects (inline
      boxes, images and ruby always count as unit boundaries).
  - The window passed to `segment` runs from `max(pos, endp - 16)` to
    `min(len, endp + 16)`.
- **`lvtextfm_vert.cpp`, phase 1 squeeze-in:** at the break test (1368), a
  CJK character that overflows by no more than the column's available shrink
  is accepted, together with the kinsoku followers it needs. Hanging keeps
  priority for 、。.
- **`lvtinydom.cpp:484` (upstream file, one line):**
  `hash = hash * 31 + JpWords::getHash();`
- **`crengine/CMakeLists.txt` (one line):** add `src/jpwords.cpp` next to
  `src/lvfntman_vert.cpp`. Check that koreader-base compiles crengine from
  this list.

### koreader-base: `cre.cpp` bindings

The functions sit in one block next to `setUserHyphenationDict`, plus their
`cre_func` registration lines:

- `cre.jpSetDeinflectRules(descriptor)`
- `cre.jpDeinflect(text)` returns the same table shape as the Lua
  `transform()`: 1-based `rule_index`, flags as signed 32-bit integers.
- `cre.jpConditionFlags(pos_list)`
- `cre.jpSetDictionaries(paths)`: the `dict.sqlite3` files of the enabled
  dictionaries, opened read-only by `jpdictionary.cpp` (fork-only file in
  koreader-base; `koreader-cre` links SQLite)
- `cre.jpSetMinKeep(n)`

### koreader: Lua

- **`yomitan/language_transformer.lua` becomes a thin wrapper** with the same
  API, so `translator.lua` is unchanged.
  - The plugin now requires this fork's build; there is no Lua fallback.
  - `getUserFacingInflectionRules` and `conditionsMatch` stay in Lua.
- **`Yomitan:updateKeepWords()`** passes the enabled dictionaries' database
  paths to `cre.jpSetDictionaries` from `Yomitan:init`, before the render.
- **Settings:** "Keep words together: off / 2 / 3 letters" and "Idioms as one
  word". On change, re-render the way `ReaderUserHyph` does.

### Performance

- **Baseline:** the `rendering took … seconds` log (`readerui.lua:345`) on
  `simple_ja_noruby.epub` and on a full novel on the device.
- **Budget:** at most 15% more render time with keep-words on, and none with
  it off.
- **Cost:** one segmentation window per column (about 32 characters),
  meaning a few hundred dictionary probes, served by the prefix cache.
- **Measured on a desktop** (x86-64, the full 坊っちゃん: 88 291 characters,
  one window per 40 characters):
  - SQLite with three-character prefixes: about 53 000 queries returning
    85 000 rows, 1.3 s for the book (0.65 ms per column).
  - The same with an in-memory word list instead of SQLite: 0.25 s.
  - Two-character prefixes return far more rows (346 000 for the book with
    an unbounded cache, 1.5 million with the 50 000-key one): 2.5 s.
  - SQLite memory-mapped I/O gained 13%; it is not used, to spare address
    space on 32-bit devices.
- **If over budget:** a precomputed table of keys and flags, with a covering
  index, written into each database by `tools/yomitan_convert.py`, would make
  each query a single index lookup.
- Use timing logs only; no new diagnostic counters (AGENTS.md).

### Tests

- **Deinflection equivalence:** `spec/unit/yomitan_spec.lua` with
  `transform_cases.lua` (1522 lines) runs against the C++ code through the
  wrapper and must pass unchanged.
- **New `spec/unit/jpwords_spec.lua`:** segmentation and split costs on a
  small dictionary fixture (`spec/unit/yomitan/jpwords_dictionary/`, the
  JMdict entries these sentences can match):
  - 沈めて·いく·と
  - 飛び降りて
  - いない as いる
  - メロス as one unit
  - 救うの|だ。 costing 20
- **New `spec/unit/vertical_keep_words_spec.lua`:** an EPUB fixture where
  飛び降りる straddles a column break.
  - With `MIN = 0`, today's split.
  - With `MIN = 2`, no break with cost ≥ 8, and the squeeze-in case.
- **Regressions:** `./kodev test front -f "Vertical text"`, the Yomitan and
  bookwords specs, and `./kodev test base`.
- **Commands:** use the Nix shell, e.g. `nix develop --command ./kodev test
  front`.

## Repositories and pushing

| Path | Repository we push to | Forked from |
|---|---|---|
| `.` | `tera8m4/koreader-tategumi` (`origin`) | m-tky/koreader-tategumi |
| `base` | `tera8m4/koreader-base` | m-tky/koreader-base |
| `base/thirdparty/kpvcrlib/crengine` | `tera8m4/crengine` | m-tky/crengine |

**Rule:** never push to a repository outside `tera8m4/`. The `m-tky` and
upstream repositories are only fetched from (to pick up their changes).

Already done:

- The forks `tera8m4/koreader-base` and `tera8m4/crengine` exist. They contain
  the pinned commits `b36c1dcd` and `8477d5f4`.
- `.gitmodules`: the `base` URL is now `https://github.com/tera8m4/koreader-base.git`.
- `base/.gitmodules`: the crengine URL is now
  `https://github.com/tera8m4/crengine.git`. This is committed on base's
  `ja-keep-words` branch, so step 2 below is done.
- `scripts/push-chain.sh`:
  - pushes the submodules to a `tera8m4` remote, which it adds when missing
  - refuses any push URL outside `github.com/tera8m4/`

Steps:

1. **Check out only what is edited** (not recursive):
   - `git submodule sync base`
   - `git submodule update --init base`
   - `git -C base submodule update --init thirdparty/kpvcrlib/crengine`
2. **In the first base commit,** change `base/.gitmodules` so the crengine URL
   is `https://github.com/tera8m4/crengine.git`. CI fetches submodules by SHA
   from these URLs, so new crengine commits must come from the fork.
3. **Create a branch per repository** (`ja-keep-words`) and commit bottom-up:
   - crengine: `jpwords.*`, `lvtextfm_vert.cpp`, the CMake line, the
     `lvtinydom.cpp` line
   - base: `.gitmodules`, the `cre.cpp` block, the crengine pointer
   - koreader: Lua, specs, docs, the base pointer
4. **Build and test locally** in the Nix shell.
5. **Publish:**
   - Merge each branch to `master`.
   - Run `scripts/push-chain.sh --dry-run`, then `scripts/push-chain.sh
     crengine`.
   - The script pushes crengine, then base, then koreader, so every parent
     pointer exists on the child fork's `master` first.
6. **Keep rebasing on upstream cheap:**
   - New code goes in fork-only files.
   - Upstream files get only:
     - one line in `lvtinydom.cpp`
     - one line in `CMakeLists.txt`
     - one block plus registration lines in `cre.cpp`
     - `base/.gitmodules`
     - the `koreader-cre` lines in `thirdparty/cmake_modules/koreader_targets.cmake`
       (`jpdictionary.cpp`, `sqlite::sqlite3`)

Not covered here: the release and OTA download URLs in
`.github/workflows/{nightly,release}.yml` and `frontend/ui/otamanager.lua`
still point at `m-tky/koreader-tategumi`. They only download, never push.
Change them separately if releases should come from the tera8m4 repository.

## Phases

| Phase | What it delivers | Repositories |
|---|---|---|
| 1 | JLReq squeeze-in at the vertical break test; kinsoku cascade moved into a helper | crengine |
| 2 | `JpDeinflector` in C++, `cre` bindings, Lua wrapper; Yomitan specs green | crengine, base, koreader |
| 3 | `JpDictionary` over the Yomitan databases, segmentation, units, break scoring, settings, render hash, specs | all three |
| 4 (optional) | Same rule in `processParagraphHorizontal` for horizontal Japanese | crengine |

Each phase lands through the push chain on its own.

## Implementation status

Phases 1–3 are implemented on the `ja-keep-words` branches. They have not been
built or run as a whole yet; CI is the first full build. What was checked
locally:

- `jpwords.cpp` compiled on its own with `clang++`:
  - `JpDeinflector` passes all 1446 cases of `transform_cases.lua`. On every
    test source, its results (text, conditions, trace) are identical to the
    Lua port's.
  - Segmentation, units and split costs match the demo at every position of
    every paragraph of `samples.json`.
- With `jpdictionary.cpp` and SQLite 3.54.0 (the version koreader-base
  builds) on the JMdict database, the split costs are again identical to the
  demo's, whose flags come from `make_words.py`. The spec fixture gives the
  same results as the full JMdict for the spec sentences.
- `lvtextfm.cpp` and `cre.cpp` pass `clang++ -fsyntax-only` with stub
  headers.

Differences from the plan:

- **Segmentation:** characters other than Japanese letters (Latin, digits,
  symbols, and U+FFFC for inline objects) are units of their own.
  - When two paths cost the same, the later split wins (反駁|した). This
    matches the demo's results on the samples, where floating point decides
    such ties.
  - Only an unknown *single* kana counts as a particle, as
    [Units](#units) says. The demo also treats unknown 2-letter katakana as
    particles.
- **Window edges:** breaks at the window edges cost 0, and earlier breaks
  are considered only inside the window. Breaks more than 16 characters back
  would cost more than 16 em of gain anyway.
- **Squeeze-in:** in phase 1 and in the scoring, squeeze-in only applies to
  columns that `applyVerticalJustification` really shrinks:
  - justified columns
  - not indented (`y <= 0`)
  - not the paragraph's last column, unless `text-align-last` is `justify`

  Elsewhere the overflow would be drawn past the column bottom (see
  `#reported_sentence_wrap` in `vertical_column_bottom_spec.lua`).
- **Extra bindings:**
  - `cre.jpSetKeepIdioms(bool)` for "Idioms as one word"
  - `cre.jpSegment(text)` for `jpwords_spec.lua`
  - `cre.jpConditionFlags(list, true)`, which takes any condition types
- **One rule set:** the engine holds a single deinflection rule set.
  `LanguageTransformer:addDescriptor()` replaces it.
- **Default:** keep-words is off; it is under *Yomitan dictionaries → Keep
  words together*.
- **No word list file:** words are looked up in the dictionary databases
  directly (see `JpDictionary`), instead of a `words.tsv` built from them.
- **Re-rendering:** a change of these settings calls `requestRender()`
  before `UpdatePos`. Settings that are not document properties do not
  request a render by themselves.

Still to do:

- Measure render time on a device against the budget in
  [Performance](#performance). From the desktop numbers, keep-words could
  cost several seconds per full render of a novel on an e-reader.
- Run the specs in CI and tune the assertions of
  `vertical_keep_words_spec.lua` if needed. It assumes about 50 characters
  per column at most.

## Licensing

- The deinflection port carries Yomitan's GPL-3.0-or-later notice, like the
  Lua port.
- Check crengine's license header before adding GPLv3 files to it. The
  combined work must remain distributable under KOReader's AGPLv3.
  - Checked: crengine's `README.TXT` says "GNU GPL license, version 2". Its
    file headers name the GPL without a version.
  - `jpwords.h` and `jpwords.cpp` carry the GPL-3.0-or-later notice.
  - Combining them is fine only if crengine is GPL-2.0-or-later, as
    KOReader's AGPLv3 distribution already assumes. This is still open: if
    the "or later" reading does not hold, the deinflector has to move out of
    crengine.

## Open questions

- **Default:** should keep-words be on by default when dictionaries are
  installed?
- **Tuning:** the gain weight versus the okurigana cost, if columns turn out
  too loose on the device.
- **Other dictionaries:** whether non-JMdict dictionaries (monolingual,
  without `prt`/`uk` tags or ⭐ term tags) should contribute words, or only
  dictionaries that have these tags.
