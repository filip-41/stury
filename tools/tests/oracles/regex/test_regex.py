"""Random ECMA patterns and texts run through core/regex (main.odin) and Node's RegExp with the `u` flag, reporting where
the verdict, the match or a group's bounds differ. A seeded grammar makes each pattern from what a JSON Schema's `pattern`
uses, over short texts of the characters the patterns name.
"""

import json
import os
import random
import shutil
import subprocess

import pytest

from capped import ROOT

CASES = 6000

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
# Alternatives of characters no text holds, which change no match but make a group's body long enough that a count
# of it runs as a counter loop rather than written out.
FILL = "".join("|" + chr(0xE000 + k) for k in range(700))
COUNTED = ["{4}", "{1,4}", "{0,4}?", "{4,}", "{2,5}", "{3,6}?"]


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
        if repeatable and atom.startswith("(") and rng.randrange(8) == 0:
            out.append(atom[:-1] + FILL + ")" + rng.choice(COUNTED))
        else:
            out.append(atom + (rng.choice(QUANTIFIERS) if repeatable else ""))
    return "".join(out)


def case_pattern(rng):
    """A pattern, one in four of them beginning with look-aheads after `^`, which the automaton runs as a product."""
    if rng.randrange(4):
        return pattern(rng, 2)
    looks = "".join(rng.choice(["(?=", "(?!"]) + pattern(rng, 1) + ")" for _ in range(rng.randint(1, 3)))
    return "^" + looks + pattern(rng, 2)


def text(rng):
    return "".join(rng.choice("aaabbcé😀A1 ") for _ in range(rng.randrange(11)))


def known(p, ours, node):
    """Why `ours` may differ from `node` on purpose, or None."""
    return INSIDE if node == "inside" else None


@pytest.fixture(scope="module")
def probe(odin, tmp_path_factory):
    if shutil.which("node") is None:
        pytest.skip("node is not on PATH")
    binary = str(tmp_path_factory.mktemp("regex") / "ecma_probe")
    subprocess.run([odin, "build", os.path.dirname(__file__), "-o:speed", f"-out:{binary}"], cwd=ROOT, check=True)
    return binary


def test_ecma_matches_as_node(probe, seed, request, tmp_path):
    rng = random.Random(seed)
    cases = [[case_pattern(rng), text(rng)] for _ in range(request.config.getoption("--cases") or CASES)]
    corpus = json.dumps(cases).encode()
    path = tmp_path / "cases.json"
    path.write_bytes(corpus)
    ours = subprocess.run([probe, str(path)], capture_output=True, check=True).stdout.decode().splitlines()
    node = subprocess.run(["node", "-e", NODE], input=corpus, capture_output=True, check=True).stdout.decode().splitlines()
    differ = [f"{p!r} on {s!r}: core/regex {a}, node {b}" for (p, s), a, b in zip(cases, ours, node) if a != b and not known(p, a, b)]
    assert not differ, f"{len(differ)} of {len(cases)} cases differ:\n" + "\n".join(differ[:20])
