#!/usr/bin/env python3
"""Build the self-contained offline demo page (linebreak_demo.html).

Needs, next to this script: words.txt (make_words.py), transforms.json
(luajit dump.lua ../../plugins/yomitan.koplugin/yomitan/data/transforms_ja.lua > transforms.json)
and budoux.mjs (https://cdn.jsdelivr.net/npm/budoux@0.7.0/+esm).
Also writes logic_check.js, which prints break statistics: node logic_check.js
"""

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def write(name, text):
    with open(os.path.join(HERE, name), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


src = read("page.src.html")
ymjs = read("yomitan-mini.js")
html = (src.replace("/*SAMPLES*/null", json.dumps(json.loads(read("samples.json")), ensure_ascii=False))
           .replace("/*PHRASES*/null", json.dumps(json.loads(read("phrases.json")), ensure_ascii=False))
           .replace("/*TRANSFORMS*/null", read("transforms.json"))
           .replace("/*WORDS*/null", json.dumps(read("words.txt"), ensure_ascii=False).replace("</", "<\\/")))

# BudouX ESM -> global, wrapped so its minified names don't clash with the page script
bud = read("budoux.mjs")
m = re.search(r"export\{([^}]*)\};?", bud)
pairs = [p.strip().split(" as ") for p in m.group(1).split(",")]
bud = bud[:m.start()] + "window.BudouX={" + ",".join(f"{b}:{a}" for a, b in pairs) + "};" + bud[m.end():]
bud = re.sub(r"//# sourceMappingURL=.*", "", bud)

# Offline: no web fonts, no CDN import
html = re.sub(r'<link rel="(preconnect|stylesheet)"[^>]*>\n', "", html)
old = '''import("https://cdn.jsdelivr.net/npm/budoux@0.7.0/+esm")
  .then(m => { parser = m.loadDefaultJapaneseParser(); budouxState = "live"; render(); })
  .catch(() => { budouxState = "failed"; render(); });'''
assert old in html
html = html.replace(old, 'try { parser = window.BudouX.loadDefaultJapaneseParser(); budouxState = "live"; } catch (e) { budouxState = "failed"; }')
html = html.replace("<script>\nconst SAMPLES",
                    "<script>\n(function(){\n" + bud + "\n})();\n</script>\n<script>\n" + ymjs + "\n</script>\n<script>\nconst SAMPLES", 1)
html = ('<!doctype html>\n<html lang="en">\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n' + html + "\n</html>\n")
write("linebreak_demo.html", html)

# Layout logic without the DOM, for node
js = html.split("<script>\nconst SAMPLES")[1].split("</script>")[0]
logic = js.split("const esc")[0]
write("logic_check.js", ymjs + "\nconst SAMPLES" + logic + '''
const state = { minKeep: 2 };
const ym = makeYomitan(YM_TRANSFORMS, YM_WORDS);
const str = (p, list) => { const ch = Array.from(p); return list.map(x => ch.slice(x.s, x.e).join("")); };
for (const k of Object.keys(SAMPLES)) for (const L of [8, 10, 12, 14, 18]) {
  const paras = paragraphs(SAMPLES[k]);
  const raw = paras.map(p => ymSegment(ym, p, { ignoreIdioms: true }));
  const segs = { budoux: PRE[k], words: raw.map((w, i) => str(paras[i], w)), units: raw.map((w, i) => str(paras[i], ymUnits(w))) };
  const out = [];
  for (const [name, m, seg] of [["today", "fork", null], ["bx", "keep", "budoux"], ["words", "keep", "words"], ["units", "keep", "units"]]) {
    const lines = layout(paras, m, L, seg ? segs[seg] : null, segs.units, segs.words);
    let bad = 0, split = 0, loose = 0;
    for (const ln of lines) { const r = place(ln, L, true); if (r.bad) bad++; if (r.split) split++; if (!ln.last) loose = Math.max(loose, r.adj); }
    out.push(`${name}:${lines.length}cols/${bad}kinsoku/${split}badsplits/+${loose.toFixed(1)}em`);
  }
  console.log(k.padEnd(9), String(L).padStart(2), out.join("  "));
}
''')
print("built", os.path.join(HERE, "linebreak_demo.html"))
