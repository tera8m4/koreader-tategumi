// Demo-only port of plugins/yomitan.koplugin/yomitan/language_transformer.lua
// plus greedy longest-match word segmentation over a JMdict word list.
// This is what the planned C++ JpDeinflector / JpWords would do in crengine.
function makeYomitan(desc, wordsText) {
  // ---- condition flags (LanguageTransformer:_getConditionFlagsMap) ----
  const flagsMap = {};
  let nextFlag = 0;
  let targets = desc.conditions;
  while (targets.length) {
    const next = [];
    for (const c of targets) {
      let flags;
      if (!c.sub_conditions) {
        flags = (1 << nextFlag) | 0;
        nextFlag++;
      } else {
        flags = 0;
        for (const s of c.sub_conditions) {
          if (flagsMap[s] === undefined) { flags = undefined; break; }
          flags |= flagsMap[s];
        }
      }
      if (flags === undefined) next.push(c); else flagsMap[c.id] = flags;
    }
    if (next.length === targets.length) throw new Error("Cycle in condition declarations");
    targets = next;
  }
  const posFlags = {};
  for (const c of desc.conditions) if (c.is_dictionary_form && flagsMap[c.id] !== undefined) posFlags[c.id] = flagsMap[c.id];
  const strict = list => {
    let f = 0;
    for (const id of list) { if (flagsMap[id] === undefined) throw new Error("bad condition " + id); f |= flagsMap[id]; }
    return f;
  };
  const lastChar = s => { const a = Array.from(s); return a[a.length - 1]; };

  const transforms = desc.transforms.map(t => {
    const lastChars = new Set();
    let always = false;
    const rules = t.rules.map(r => {
      const rule = { type: r[0], inf: r[1], def: r[2], cin: strict(r[3]), cout: strict(r[4]) };
      if (rule.type === "prefix" || rule.inf === "") always = true; else lastChars.add(lastChar(rule.inf));
      return rule;
    });
    return { id: t.id, rules, lastChars, always };
  });

  const matches = (rule, text) =>
    rule.type === "suffix" ? text.endsWith(rule.inf)
      : rule.type === "prefix" ? text.startsWith(rule.inf)
        : text === rule.inf;
  const apply = (rule, text) =>
    rule.type === "suffix" ? text.slice(0, text.length - rule.inf.length) + rule.def
      : rule.type === "prefix" ? rule.def + text.slice(rule.inf.length)
        : rule.def;

  // LanguageTransformer:transform (same breadth-first order and cycle check)
  function deinflect(src) {
    const res = [{ text: src, cond: 0, parent: -1, t: -1, r: -1 }];
    for (let i = 0; i < res.length; i++) {
      const cur = res[i], text = cur.text, last = lastChar(text);
      for (let ti = 0; ti < transforms.length; ti++) {
        const tr = transforms[ti];
        if (!(tr.always || tr.lastChars.has(last))) continue;
        for (let ri = 0; ri < tr.rules.length; ri++) {
          const rule = tr.rules[ri];
          if (!(cur.cond === 0 || (cur.cond & rule.cin) !== 0) || !matches(rule, text)) continue;
          let cycle = false;
          for (let n = i; res[n].parent >= 0; n = res[n].parent) {
            const nd = res[n];
            if (nd.t === ti && nd.r === ri && res[nd.parent].text === text) { cycle = true; break; }
          }
          if (!cycle) res.push({ text: apply(rule, text), cond: rule.cout, parent: i, t: ti, r: ri });
        }
      }
    }
    return res;
  }

  // ---- word list: "term \t pos-rules \t flags" (p = particle/auxiliary/copula, x = idiom only) ----
  const words = new Map();
  for (const line of wordsText.split("\n")) {
    const a = line.indexOf("\t"), b = line.indexOf("\t", a + 1);
    if (a < 0) continue;
    let f = 0;
    const rules = line.slice(a + 1, b);
    if (rules) for (const r of rules.split(" ")) f |= posFlags[r] || 0;
    const fl = line.slice(b + 1);
    words.set(line.slice(0, a), { flags: f, p: fl.includes("p"), x: fl.includes("x"), c: fl.includes("c"), w: fl.includes("w") });
  }

  // Dictionary entry for `text` as Yomitan would find it (deinflected, conditions
  // checked). When several deinflections match, prefer a common entry that is
  // normally written this way (いない as いる, not as a kana spelling of 居ない).
  function lookup(text, opts) {
    let found = null, best = -1;
    for (const d of deinflect(text)) {
      const e = words.get(d.text);
      if (!e || (opts.ignoreIdioms && e.x)) continue;
      if (d.cond === 0 || (d.cond & e.flags) !== 0) {
        const score = (e.c ? 2 : 0) + (e.w ? 1 : 0);
        if (score > best) { best = score; found = { e }; }
        if (score === 3) break;
      }
    }
    return found;
  }

  return { deinflect, lookup, size: words.size };
}

const YM_OPEN = new Set(Array.from("「『（【〔〈《“‘［｛"));
const YM_TRAIL = new Set(Array.from("」』）】〕〉》”’］｝。．、，・：；！？…‥"));
const YM_KANA = /^[ぁ-ゟ゠-ヿ]$/;
const YM_KANJI = /[㐀-鿿々]/;
const YM_KATA_RUN = /^[ァ-ヺー]{2,}$/;

// Best segmentation of each run between punctuation marks: the cheapest sequence
// of dictionary words (deinflected). Costs: common word 1, other word with kanji
// 1.2, other kana-only word 2.5 (obscure kana entries such as くと, or kana
// spellings of kanji words such as たから, are the usual false matches), unknown
// katakana run 2, unknown single character 3.5. Greedy longest match (Yomitan's scan from a tapped
// character) gets 沈めてい|く wrong; this picks 沈めて|いく.
// Returns words: [{s, e, p}] where p = particle/auxiliary/copula; punctuation is
// glued on (closing marks to the previous word, opening brackets to the next one).
const YM_MAXLEN = 16;
function ymBestPath(ym, ch, a, b, opts) {
  const m = b - a, cost = new Array(m + 1).fill(Infinity), back = new Array(m + 1), hit = new Array(m + 1);
  cost[0] = 0;
  for (let i = 0; i < m; i++) {
    if (cost[i] === Infinity) continue;
    for (let L = 1; L <= Math.min(YM_MAXLEN, m - i); L++) {
      const sub = ch.slice(a + i, a + i + L).join("");
      const h = ym.lookup(sub, opts);
      let c;
      if (h) {
        const kanji = YM_KANJI.test(sub);
        // A kana-only match of a word normally written in kanji (たから for 宝) is weak.
        c = kanji ? (h.e.c ? 1 : 1.2) : (h.e.c && h.e.w ? 1 : 2.5);
      } else {
        // Unknown: one character, or a whole katakana run (names, loanwords: メロス).
        c = L === 1 ? 3.5 : (YM_KATA_RUN.test(sub) ? 2 : Infinity);
      }
      if (cost[i] + c < cost[i + L]) { cost[i + L] = cost[i] + c; back[i + L] = i; hit[i + L] = h; }
    }
  }
  const out = [];
  for (let j = m; j > 0; j = back[j]) {
    const i = back[j], h = hit[j];
    out.push({ s: a + i, e: a + j, n: j - i, p: h ? h.e.p : YM_KANA.test(ch[a + i]), known: !!h });
  }
  return out.reverse();
}

function ymSegment(ym, text, opts) {
  const ch = Array.from(text), n = ch.length, words = [];
  let i = 0, pendingOpen = -1;
  while (i < n) {
    const c = ch[i];
    if (YM_OPEN.has(c)) { if (pendingOpen < 0) pendingOpen = i; i++; continue; }
    if (YM_TRAIL.has(c) || /\s/.test(c)) {
      if (words.length && pendingOpen < 0) words[words.length - 1].e = i + 1;
      else { words.push({ s: pendingOpen >= 0 ? pendingOpen : i, e: i + 1, p: false, punct: true }); pendingOpen = -1; }
      i++;
      continue;
    }
    let run = i;
    while (run < n && !YM_OPEN.has(ch[run]) && !YM_TRAIL.has(ch[run]) && !/\s/.test(ch[run])) run++;
    const seg = ymBestPath(ym, ch, i, run, opts);
    if (pendingOpen >= 0) { seg[0].s = pendingOpen; pendingOpen = -1; }
    words.push(...seg);
    i = run;
  }
  return words;
}

// Words -> units: a word plus the short (up to 2 letters) particles, auxiliaries
// and copulas that follow it (事が, 来たかも); longer ones (ばかり, している) start
// their own unit so that a column may start with them.
function ymUnits(words) {
  const units = [];
  for (const w of words) {
    const last = units[units.length - 1];
    if (last && ((w.p && w.n <= 2) || w.punct)) { last.e = w.e; last.words.push(w); }
    else units.push({ s: w.s, e: w.e, words: [w] });
  }
  return units;
}

if (typeof module !== "undefined") module.exports = { makeYomitan, ymSegment, ymUnits };
