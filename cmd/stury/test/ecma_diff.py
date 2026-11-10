#!/usr/bin/env python3
"""Random ECMA patterns and texts run through core/regex (ecma_probe.odin) and Node's RegExp with the `u` flag,
reporting where the verdict, the match or a group's bounds differ.

    python3 cmd/stury/test/ecma_diff.py [--odin PATH] [--seed 1] [--cases 6000] [--show 20]

A seeded grammar makes each pattern from what a JSON Schema's `pattern` uses: characters, `.`, classes and the class
escapes, anchors and \\b, groups with and without names, alternatives, look-aheads, and every quantifier, lazy or
not, over bodies that can match empty or not. Texts are short, over the characters the patterns name. Without node
on PATH nothing is compared.
"""

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

# Where Node answers otherwise against the spec: V8 tries a negative look-ahead between the two halves of a surrogate
# pair, so `(?!.)` finds "😀" at 1.
INSIDE = "Node stopping inside a surrogate pair"

NODE = r"""
for (const [p, s] of JSON.parse(require("fs").readFileSync(0, "utf8"))) {
  let m;
  try { m = new RegExp(p, "ud").exec(s); } catch { console.log("E"); continue; }
  if (!m) { console.log("-"); continue; }
  const at = x => [...s.slice(0, x)].length;
  const inside = x => x > 0 && x < s.length && /[\ud800-\udbff]/.test(s[x - 1]) && /[\udc00-\udfff]/.test(s[x]);
  if (m.indices.some(g => g && g.some(inside))) { console.log("inside"); continue; }
  console.log(m.indices.map(g => g ? `${at(g[0])} ${at(g[1]) - at(g[0])}` : "-1 -1").join(" "));
}
"""

ATOMS = ["a", "b", "c", ".", "[^a]", "[a-c]", "[\\d\\s]", "\\w", "\\W", "é", "😀", "\\p{L}", "\\P{Ll}", "\\u{1F600}",
         "\\x61", "[\\u0061-b]"]
ASSERTIONS = ["^", "$", "\\b", "\\B"]
QUANTIFIERS = ["", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{2,}", "{0,2}?", "{0}", "{3}?"]


def pattern(rng, depth):
    out = []
    for _ in range(rng.randint(1, 3)):
        k = rng.randrange(14)
        repeatable = True
        if k < 6 or depth == 0:
            atom = rng.choice(ATOMS)
        elif k == 6:
            atom, repeatable = rng.choice(ASSERTIONS), False
        elif k in (7, 8):
            atom = "(" + pattern(rng, depth - 1) + ")"
        elif k == 9:
            atom = "(?<n%d>" % rng.randrange(1000) + pattern(rng, depth - 1) + ")"
        elif k == 10:
            atom = "(?:" + "|".join(pattern(rng, depth - 1) for _ in range(rng.randint(2, 3))) + ")"
        elif k == 11:
            atom = "(?:" + pattern(rng, depth - 1) + "|)"
        else:
            atom, repeatable = rng.choice(["(?=", "(?!"]) + pattern(rng, depth - 1) + ")", False
        out.append(atom + (rng.choice(QUANTIFIERS) if repeatable else ""))
    return "".join(out)


def text(rng):
    return "".join(rng.choice("aaabbcé😀A1 ") for _ in range(rng.randrange(11)))


def known(p, ours, node):
    """Why `ours` may differ from `node` on purpose, or None."""
    if node == "inside":
        return INSIDE
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--cases", type=int, default=6000)
    parser.add_argument("--show", type=int, default=20)
    args = parser.parse_args()
    if shutil.which("node") is None:
        print("ecma_diff: node is not on PATH, so nothing was compared")
        return 0
    rng = random.Random(args.seed)
    cases = [[pattern(rng, 2), text(rng)] for _ in range(args.cases)]
    corpus = json.dumps(cases).encode()
    with tempfile.TemporaryDirectory() as scratch:
        probe = os.path.join(scratch, "ecma_probe")
        subprocess.run([args.odin, "build", "cmd/stury/test/ecma_probe.odin", "-file", "-o:speed", f"-out:{probe}"],
                       cwd=ROOT, check=True)
        with open(os.path.join(scratch, "cases.json"), "wb") as f:
            f.write(corpus)
        ours = subprocess.run([probe, f.name], capture_output=True, check=True).stdout.decode().splitlines()
    node = subprocess.run(["node", "-e", NODE], input=corpus, capture_output=True, check=True).stdout.decode().splitlines()
    differ, as_known = [], {}
    for (p, s), a, b in zip(cases, ours, node):
        if a == b:
            continue
        if why := known(p, a, b):
            as_known[why] = as_known.get(why, 0) + 1
        else:
            differ.append((p, s, a, b))
    for p, s, a, b in differ[:args.show]:
        print(f"{p!r} on {s!r}: core/regex {a}, node {b}")
    known_counts = "".join(f", {n} for {why}" for why, n in as_known.items())
    print(f"ecma_diff seed {args.seed}: {len(cases)} cases, {len(differ)} differ{known_counts}")
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
