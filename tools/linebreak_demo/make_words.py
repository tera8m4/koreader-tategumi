#!/usr/bin/env python3
"""Build words.txt for the line breaking demo from a Yomitan JMdict zip.

Each line: key <TAB> pos-rules <TAB> flags, keys sorted by UTF-8 bytes.
Flags (see doc/Japanese_line_breaking.md, "Word flags"):
  p  particle / auxiliary / copula   x  idiom (exp) only
  c  common (term tags contain ⭐)   w  written this way (expression, or reading of a `uk` entry)

Usage: make_words.py "<path to [Bilingual] JMdict (Recommended).zip>"
"""

import collections
import json
import os
import sys
import zipfile

ATTACH = {"prt", "aux", "aux-v", "aux-adj", "cop"}


def main(zip_path):
    rules = collections.defaultdict(set)
    expr_tags = collections.defaultdict(list)
    common, written = set(), set()
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            if not name.startswith("term_bank"):
                continue
            for e in json.loads(z.read(name)):
                expr, reading, dtags, r = e[0], e[1] or e[0], e[2] or "", e[3] or ""
                tags = set(dtags.split())
                if "forms" in tags:
                    continue
                star = len(e) > 7 and "⭐" in (e[7] or "")
                for key in {expr, reading}:
                    rules[key].update(r.split())
                    if star:
                        common.add(key)
                expr_tags[expr].append(tags)
                written.add(expr)
                if "uk" in tags:
                    written.add(reading)
    lines = []
    for key in sorted(rules, key=lambda s: s.encode("utf-8")):
        if len(key) > 16:
            continue
        flags = ""
        ts = expr_tags.get(key)
        if ts:
            if any(t & ATTACH for t in ts):
                flags += "p"
            if all("exp" in t for t in ts):
                flags += "x"
        if key in common:
            flags += "c"
        if key in written:
            flags += "w"
        lines.append(f"{key}\t{' '.join(sorted(rules[key]))}\t{flags}")
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "words.txt")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print(f"{out}: {len(lines)} keys")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
