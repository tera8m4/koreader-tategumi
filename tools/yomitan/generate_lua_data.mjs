#!/usr/bin/env node
// Regenerates the Lua data tables used by plugins/yomitan.koplugin from a
// Yomitan source checkout, so that deinflection and text preprocessing stay
// byte-for-byte in sync with upstream Yomitan.
//
// This is a developer tool only; KOReader itself never runs Node.
//
// Usage:
//   node tools/yomitan/generate_lua_data.mjs <yomitan-checkout> <kanji-processor-package-dir>
//
// <kanji-processor-package-dir> is the unpacked npm package "kanji-processor"
// (the dependency Yomitan uses for its standardizeKanji text preprocessor),
// e.g. obtained with `npm pack kanji-processor@1 && tar xzf kanji-processor-*.tgz`.
//
// Outputs (relative to the repository root):
//   plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua
//   plugins/yomitan.koplugin/yomitan/data/text_ja.lua
//   spec/unit/yomitan/transform_cases.lua
//   spec/unit/yomitan/translator_cases.lua
//
// The spec fixture dictionary is regenerated separately with:
//   python3 tools/yomitan_convert.py -o <tmp> <yomitan-checkout>/test/data/dictionaries/valid-dictionary1
// and copying "<tmp>/Test Dictionary" to spec/unit/yomitan/test_dictionary.

import {execSync} from 'node:child_process';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const [yomitanDir, kanjiProcessorDir] = process.argv.slice(2).map((p) => p && resolve(p));
if (!yomitanDir || !kanjiProcessorDir) {
    console.error('usage: generate_lua_data.mjs <yomitan-checkout> <kanji-processor-package-dir>');
    process.exit(1);
}
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

let yomitanRevision = 'unknown';
try {
    yomitanRevision = execSync('git rev-parse --short HEAD', {cwd: yomitanDir}).toString().trim();
} catch (e) {
    // Not a git checkout; keep "unknown".
}
const kanjiProcessorVersion = JSON.parse(readFileSync(join(kanjiProcessorDir, 'package.json'), 'utf8')).version;

/** @param {string} relPath */
async function importYomitan(relPath) {
    return await import(pathToFileURL(join(yomitanDir, relPath)).href);
}

/** @param {string} s */
function luaString(s) {
    let out = '"';
    for (const ch of s) {
        const cp = ch.codePointAt(0);
        if (ch === '\\') { out += '\\\\'; } else if (ch === '"') { out += '\\"'; } else if (ch === '\n') { out += '\\n'; } else if (cp < 0x20 || cp === 0x7f) { out += `\\${cp}`; } else { out += ch; }
    }
    return out + '"';
}

/** @param {string[]} list */
function luaStringList(list) {
    return '{' + list.map(luaString).join(', ') + '}';
}

const REGEX_META = /[\\^$.*+?()[\]{}|]/;

/**
 * Recover the literal affix from one of Yomitan's generated RegExps.
 * @param {RegExp} regex
 * @param {string} type
 */
function literalFromRegex(regex, type) {
    let src = regex.source;
    switch (type) {
        case 'suffix':
            if (!src.endsWith('$')) { throw new Error(`unexpected suffix regex ${src}`); }
            src = src.slice(0, -1);
            break;
        case 'prefix':
            if (!src.startsWith('^')) { throw new Error(`unexpected prefix regex ${src}`); }
            src = src.slice(1);
            break;
        case 'wholeWord':
            if (!src.startsWith('^') || !src.endsWith('$')) { throw new Error(`unexpected wholeWord regex ${src}`); }
            src = src.slice(1, -1);
            break;
        default:
            throw new Error(`unknown rule type ${type}`);
    }
    if (REGEX_META.test(src)) { throw new Error(`regex ${regex.source} is not a plain literal`); }
    return src;
}

const header = (what) => `-- ${what}
-- GENERATED FILE, DO NOT EDIT. Regenerate with tools/yomitan/generate_lua_data.mjs.
-- Source: Yomitan (https://github.com/yomidevs/yomitan) revision ${yomitanRevision},
-- licensed under the GNU General Public License v3 or later.
`;

async function generateTransforms() {
    const {japaneseTransforms} = await importYomitan('ext/js/language/ja/japanese-transforms.js');
    const lines = [header('Japanese deinflection rules (ext/js/language/ja/japanese-transforms.js).')];
    lines.push('-- Rule layout: { type, inflected, deinflected, conditions_in, conditions_out }');
    lines.push('return {');
    lines.push(`    language = ${luaString(japaneseTransforms.language)},`);
    lines.push('    conditions = {');
    for (const [id, condition] of Object.entries(japaneseTransforms.conditions)) {
        const parts = [`id = ${luaString(id)}`, `name = ${luaString(condition.name)}`, `is_dictionary_form = ${condition.isDictionaryForm ? 'true' : 'false'}`];
        if (Array.isArray(condition.subConditions)) { parts.push(`sub_conditions = ${luaStringList(condition.subConditions)}`); }
        lines.push(`        { ${parts.join(', ')} },`);
    }
    lines.push('    },');
    lines.push('    transforms = {');
    let ruleCount = 0;
    for (const [id, transform] of Object.entries(japaneseTransforms.transforms)) {
        const parts = [`id = ${luaString(id)}`, `name = ${luaString(transform.name)}`];
        if (typeof transform.description === 'string') { parts.push(`description = ${luaString(transform.description)}`); }
        const ja = (transform.i18n || []).find((x) => x.language === 'ja');
        if (ja && typeof ja.name === 'string') { parts.push(`name_ja = ${luaString(ja.name)}`); }
        lines.push(`        { ${parts.join(', ')}, rules = {`);
        for (const rule of transform.rules) {
            const inflected = literalFromRegex(rule.isInflected, rule.type);
            let deinflected;
            switch (rule.type) {
                case 'suffix': deinflected = rule.deinflect(inflected).slice(0); break;
                case 'prefix': deinflected = rule.deinflect(inflected); break;
                case 'wholeWord': deinflected = rule.deinflect(inflected); break;
            }
            if (rule.type === 'suffix' && typeof rule.deinflected === 'string' && rule.deinflected !== deinflected) {
                throw new Error(`suffix rule mismatch in ${id}: ${rule.deinflected} vs ${deinflected}`);
            }
            lines.push(`            { ${luaString(rule.type)}, ${luaString(inflected)}, ${luaString(deinflected)}, ${luaStringList(rule.conditionsIn)}, ${luaStringList(rule.conditionsOut)} },`);
            ++ruleCount;
        }
        lines.push('        } },');
    }
    lines.push('    },');
    lines.push('}');
    write('plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua', lines.join('\n') + '\n');
    console.log(`transforms: ${Object.keys(japaneseTransforms.transforms).length} transforms, ${ruleCount} rules`);
}

/**
 * @param {[number, number][]} ranges
 * @returns {[string, string][]}
 */
function nfkdMap(ranges) {
    const out = [];
    for (const [min, max] of ranges) {
        for (let cp = min; cp <= max; ++cp) {
            const ch = String.fromCodePoint(cp);
            const n = ch.normalize('NFKD');
            if (n !== ch) { out.push([ch, n]); }
        }
    }
    return out;
}

async function generateTextData() {
    const {ROMAJI_TO_HIRAGANA} = await importYomitan('ext/js/language/ja/japanese-kana-romaji-dicts.js');
    const cjk = await importYomitan('ext/js/language/CJK-util.js');

    const lines = [header('Japanese text preprocessing data (romaji table, NFKD maps, kanji variants).')];
    lines.push(`-- Kanji variants come from the npm package kanji-processor ${kanjiProcessorVersion}`);
    lines.push('-- (https://www.npmjs.com/package/kanji-processor), Copyright (c) 2024 Lyroxide, MIT License.');
    lines.push('return {');

    // Ordered: Yomitan applies replaceAll for each entry in insertion order.
    lines.push('    -- ext/js/language/ja/japanese-kana-romaji-dicts.js ROMAJI_TO_HIRAGANA, in application order.');
    lines.push('    romaji_to_hiragana = {');
    for (const [romaji, kana] of Object.entries(ROMAJI_TO_HIRAGANA)) {
        lines.push(`        { ${luaString(romaji)}, ${luaString(kana)} },`);
    }
    lines.push('    },');

    const emitMap = (name, comment, pairs) => {
        lines.push(`    -- ${comment}`);
        lines.push(`    ${name} = {`);
        for (const [k, v] of pairs) { lines.push(`        [${luaString(k)}] = ${luaString(v)},`); }
        lines.push('    },');
    };
    emitMap('cjk_compatibility_nfkd', 'normalizeCJKCompatibilityCharacters: NFKD of U+3300..U+33FF.', nfkdMap([cjk.CJK_COMPATIBILITY]));
    emitMap('radicals_nfkd', 'normalizeRadicalCharacters: NFKD of the Kangxi radicals, CJK radicals supplement and CJK strokes blocks.', nfkdMap(cjk.CJK_RADICALS_RANGES));

    // kanji-processor builds a RegExp character class without the "u" flag, so
    // only BMP variants can ever match (astral ones are split into surrogate
    // halves that are absent from the map). Mirror that behaviour.
    const fullList = JSON.parse(readFileSync(join(kanjiProcessorDir, 'dist', 'full_list.json'), 'utf8'));
    const itaijiList = JSON.parse(readFileSync(join(kanjiProcessorDir, 'dist', 'itaiji_list.json'), 'utf8'));
    const conversionMap = new Map();
    for (const {oyaji, itaiji} of fullList) {
        for (const v of itaiji) { conversionMap.set(v, oyaji); }
    }
    const kanjiPairs = [];
    const seen = new Set();
    for (const v of itaijiList.join('')) {
        if (v.length !== 1 || seen.has(v)) { continue; }
        seen.add(v);
        const parent = conversionMap.get(v);
        if (typeof parent === 'string' && parent !== v) { kanjiPairs.push([v, parent]); }
    }
    emitMap('kanji_variants', 'standardizeKanji: kanji variant (itaiji) -> standard form (oyaji).', kanjiPairs);
    lines.push('}');
    write('plugins/yomitan.koplugin/yomitan/data/text_ja.lua', lines.join('\n') + '\n');
    console.log(`text data: ${Object.keys(ROMAJI_TO_HIRAGANA).length} romaji, ${kanjiPairs.length} kanji variants`);
}

async function generateTransformCases() {
    const source = readFileSync(join(yomitanDir, 'test', 'language', 'japanese-transforms.test.js'), 'utf8');
    const start = source.indexOf('const tests = [');
    const end = source.indexOf('/* eslint-enable');
    if (start < 0 || end < 0) { throw new Error('could not locate the tests array'); }
    const literal = source.slice(start + 'const tests = '.length, end).trim().replace(/;$/, '');
    const tests = new Function(`return ${literal};`)();
    const lines = [header('Deinflection test cases from test/language/japanese-transforms.test.js.')];
    lines.push('-- Case layout: { term, source, rule (or false), reasons (or false) }');
    lines.push('return {');
    let count = 0;
    for (const {category, valid, tests: cases} of tests) {
        lines.push(`    { category = ${luaString(category)}, valid = ${valid ? 'true' : 'false'}, tests = {`);
        for (const {term, source: src, rule, reasons} of cases) {
            const ruleLua = rule === null ? 'false' : luaString(rule);
            const reasonsLua = reasons === null ? 'false' : luaStringList(reasons);
            lines.push(`        { ${luaString(term)}, ${luaString(src)}, ${ruleLua}, ${reasonsLua} },`);
            ++count;
        }
        lines.push('    } },');
    }
    lines.push('}');
    write('spec/unit/yomitan/transform_cases.lua', lines.join('\n') + '\n');
    console.log(`transform cases: ${count}`);
}

// Expected translator results for the Japanese term lookups in
// test/data/translator-test-inputs.json, reduced to the fields the Lua port
// produces. They are checked against spec/unit/yomitan/test_dictionary, which
// is test/data/dictionaries/valid-dictionary1 converted with
// tools/yomitan_convert.py (so row ids match Yomitan's ids).
async function generateTranslatorCases() {
    const inputs = JSON.parse(readFileSync(join(yomitanDir, 'test', 'data', 'translator-test-inputs.json'), 'utf8'));
    const results = JSON.parse(readFileSync(join(yomitanDir, 'test', 'data', 'translator-test-results.json'), 'utf8'));
    const lines = [header('Expected translator results from test/data/translator-test-results.json.')];
    lines.push('return {');
    let count = 0;
    inputs.tests.forEach((test, i) => {
        if (test.func !== 'findTerms' || !['split', 'group', 'term'].includes(test.mode)) { return; }
        const options = {...inputs.optionsPresets.default};
        if (Array.isArray(test.options)) {
            for (const o of test.options) { Object.assign(options, typeof o === 'string' ? inputs.optionsPresets[o] : o); }
        }
        // Text replacements, primary readings and other languages are not supported.
        if (options.language !== 'ja' || (options.textReplacements || [null]).some((x) => x !== null) || options.primaryReading || options.searchResolution === 'word') { return; }
        const result = results[i];
        if (result.name !== test.name) { throw new Error(`result mismatch for ${test.name}`); }
        lines.push(`    { name = ${luaString(test.name)}, text = ${luaString(test.text)}, mode = ${luaString(test.mode)}, remove_non_japanese = ${options.removeNonJapaneseCharacters ? 'true' : 'false'}, entries = {`);
        for (const e of result.dictionaryEntries) {
            const headwords = e.headwords.map((h) => `{ ${luaString(h.term)}, ${luaString(h.reading)}, tags = ${luaStringList(h.tags.map((t) => t.name))}, sources = ${luaStringList(h.sources.map((s) => `${s.originalText}|${s.transformedText}|${s.deinflectedText}|${s.matchSource}|${s.isPrimary}`))} }`);
            const chains = e.inflectionRuleChainCandidates.map((c) => luaString(`${c.source}:${c.inflectionRules.map((r) => r.name).join(',')}`));
            const definitions = e.definitions.map((d) => `{ id = ${d.id}, headword_indices = {${d.headwordIndices.join(', ')}}, tags = ${luaStringList(d.tags.filter((t) => !t.redundant).map((t) => t.name))} }`);
            lines.push(`        { score = ${e.score}, max_original_text_length = ${e.maxOriginalTextLength}, source_term_exact_match_count = ${e.sourceTermExactMatchCount},`);
            lines.push(`          headwords = { ${headwords.join(', ')} },`);
            lines.push(`          chains = { ${chains.join(', ')} },`);
            lines.push(`          definitions = { ${definitions.join(', ')} } },`);
        }
        lines.push('    } },');
        ++count;
    });
    lines.push('}');
    write('spec/unit/yomitan/translator_cases.lua', lines.join('\n') + '\n');
    console.log(`translator cases: ${count}`);
}

/**
 * @param {string} relPath
 * @param {string} content
 */
function write(relPath, content) {
    const full = join(repoRoot, relPath);
    mkdirSync(dirname(full), {recursive: true});
    writeFileSync(full, content);
}

await generateTransforms();
await generateTextData();
await generateTransformCases();
await generateTranslatorCases();
