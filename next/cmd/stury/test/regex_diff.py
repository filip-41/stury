#!/usr/bin/env python3
"""Random regular expressions and texts run through build/stury and jq 1.8.2 (Oniguruma), reporting where
they differ.

    python3 cmd/stury/test/regex_diff.py [build/stury] [--seed 1] [--cases 20000] [--show 20] [--jq jq]

jq_diff.py's sibling for the regex builtins: a seeded grammar makes each pattern from Oniguruma's syntax as
jq compiles it (look-around, backreferences and conditions, named groups, greedy, lazy and possessive
quantifiers, \\K, \\R, \\X, class intersection, properties, anchors, inline options, subexpression calls
\\g<...> and \\g'...', the absent operator (?~...) in its four forms, the callouts (*FAIL),
(*MISMATCH), (*SKIP), (*ERROR), and (*COUNT), (*TOTAL_COUNT), (*MAX) and (*CMP) with their tags), a set of
jq's flags (g, i, x, n, s, l, m, p) and a text of ASCII and multi-byte characters, and runs one of match,
test, capture, scan, splits, sub or gsub on them. A case differs, or differs as documented, as in
jq_diff.py; SKIP lists what stury differs in on purpose. Each run is held to TIMEOUT seconds of CPU, and the peak RSS of any one is reported.
"""

import os
import random
import re
import resource
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jq_diff import main

STARTS_SEEN = ("a callout that aborts the search, or a total count read back, sees which starts are tried, "
               "which is Oniguruma's optimizer's choice (a minimum length, the literal it searches by); stury "
               "skips as it does by literals, ASCII classes, (?i) runes and look-ahead, not in all of its choices")

# (regex on "FLAGS PATTERN", why stury answers otherwise), checked before a case runs.
# Not generated, and known to differ: a lazy `{n,}?` with n >= 2 over a body that can match empty and holds
# a capture, which Oniguruma compiles by the body's size (copies and a loop when n times its ops is at most
# 10, else OP_REPEAT_NG, whose empty check leaves the repeat) and stury always as copies and a loop.
SKIP = [
    (r"\(\*ERROR(\)|\{(?!-1\}))", STARTS_SEEN),
    (r"\(\*TOTAL_COUNT\[(t\d+)\].*(\{\1[,}]|,\1\})", STARTS_SEEN),
]

CHARS = ["a", "b", "c", "A", "B", "x", "0", "1", "_", " ", "-", ".", "é", "É", "ß", "ẞ", "İ", "ı", "i", "I", "K",
         "k", "ſ", "s", "S", "Σ", "σ", "ς", "😀", "日", "\u0301", "\r", "\n", "\t", "²", "½", "α", "б"]
TEXT_PIECES = CHARS + ["ab", "abc", "aa", "bb", "ss", "e\u0301", "\r\n", "👨\u200d👩\u200d👧", "🇵🇱", "日本",
                       "Straße", "ΣΑΣ", "abcabc", "a1b2", "  ", "ﬁ"]
CLASS_ITEMS = ["a", "b", "a-c", "0-9", "x-z", "é", "ß", "😀", "\\w", "\\W", "\\d", "\\s", "\\h", "[:alpha:]",
               "[:^digit:]", "[:upper:]", "[:word:]", "[:punct:]", "\\p{L}", "\\p{Greek}", "\\P{Lu}", "\\n",
               "\\x41", "\\u00e9", "-", "^", ".", "[ab]", "A-Z"]
ESCAPES = ["\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\h", "\\H", "\\R", "\\X", "\\N", "\\O", "\\p{L}",
           "\\p{Lu}", "\\p{Greek}", "\\p{^Latin}", "\\P{Alpha}", "\\p{Word}", "\\p{Emoji}", "\\p{In_Basic_Latin}",
           "\\x{e9}", "\\u03c3", "\\t", "\\n", "\\.", "\\*", "\\(", "\\[", "\\\\", "\\/"]
ANCHORS = ["^", "$", "\\A", "\\z", "\\Z", "\\b", "\\B", "\\G"]
QUANTS = ["*", "+", "?", "{2}", "{1,2}", "{0,}", "{,2}", "{2,1}"]
FLAGS = ["", "", "", "g", "g", "i", "gi", "x", "gx", "n", "gn", "s", "gs", "l", "gl", "m", "gm", "im", "p", "gp", "gil", "gin"]


class Gen:
    def __init__(self, rnd):
        self.r = rnd

    def pattern(self):
        self.groups, self.names, self.tags, self.in_absent = 0, [], [], False
        return self.alt(3)

    def alt(self, d):
        n = self.r.choice([1, 1, 1, 2, 2, 3])
        return "|".join(self.seq(d) for _ in range(n))

    def seq(self, d):
        return "".join(self.piece(d) for _ in range(self.r.choice([0, 1, 1, 2, 2, 3, 4])))

    def piece(self, d):
        a = self.atom(d)
        if self.r.random() < 0.3:
            a += self.r.choice(QUANTS) + self.r.choice(["", "", "?", "+"])
        return a

    def atom(self, d):
        k = self.r.random()
        if d <= 0 or k < 0.35:
            return self.r.choice(CHARS[:16] + ["."] * 3) if self.r.random() < 0.5 else self.r.choice(CHARS)
        if k < 0.45:
            return self.r.choice(ESCAPES)
        if k < 0.52:
            return self.r.choice(ANCHORS)
        if k < 0.62:
            return self.cls()
        if k < 0.68 and self.groups:
            return self.backref()
        if k < 0.70:
            return "\\K"
        if k < 0.73:
            return self.r.choice(["(*FAIL)", "(*SKIP)", "(*SKIP)", "(*MISMATCH)"])
        if k < 0.76:
            return self.callout()
        if k < 0.79:
            return self.call()
        return self.group(d - 1)

    def callout(self):
        k = self.r.random()
        if k < 0.1:
            return self.r.choice(["(*ERROR)", "(*ERROR{-1})", "(*ERROR{-15})", "(*ERROR{0})"])
        def side():
            return self.r.choice(self.tags) if self.tags and self.r.random() < 0.7 else str(self.r.randint(-1, 3))
        if k < 0.35:
            return f"(*CMP{{{side()},{self.r.choice(['==', '!=', '<', '>', '<=', '>='])},{side()}}})"
        tag = ""
        if self.r.random() < 0.6:
            self.tags.append(f"t{len(self.tags)}")
            tag = f"[{self.tags[-1]}]"
        kind = self.r.choice([">", "X", "<", ""])
        if k < 0.6:
            return f"(*MAX{tag}{{{side()}{',' + kind if kind else ''}}})"
        name = self.r.choice(["COUNT", "COUNT", "TOTAL_COUNT"])
        return f"(*{name}{tag}{'{' + kind + '}' if kind else ''})"

    def call(self):
        k = self.r.random()
        if self.names and k < 0.3:
            to = self.r.choice(self.names + ["z"])
        elif k < 0.5:
            to = self.r.choice(["-", "+"]) + str(self.r.randint(0, 2))
        else:
            to = str(self.r.randint(0, self.groups + 1))
        return f"\\g'{to}'" if self.r.random() < 0.2 else f"\\g<{to}>"

    def absent(self, d):
        self.in_absent = True
        k = self.r.random()
        if k < 0.3:
            out = "(?~" + self.alt(d) + ")"
        elif k < 0.7:
            out = "(?~|" + self.alt(d) + "|" + self.alt(d) + ")"
        elif k < 0.9:
            out = "(?~|" + self.alt(d) + ")"
        else:
            out = "(?~|)"
        self.in_absent = False
        return out

    def cls(self):
        items = "".join(self.r.choice(CLASS_ITEMS) for _ in range(self.r.choice([1, 1, 2, 3])))
        if self.r.random() < 0.15:
            items += "&&" + ("[^" if self.r.random() < 0.5 else "[") + self.r.choice(CLASS_ITEMS) + "]"
        return "[" + self.r.choice(["", "", "^"]) + items + "]"

    def backref(self):
        g = self.r.randint(1, self.groups + (self.r.random() < 0.1))
        k = self.r.random()
        if self.names and k < 0.4:
            return f"\\k<{self.r.choice(self.names)}>"
        if k < 0.5:
            return f"\\k<-{self.r.randint(1, self.groups)}>"
        return f"\\{g}"

    def group(self, d):
        k = self.r.random()
        if k < 0.3:
            self.groups += 1
            return "(" + self.alt(d) + ")"
        if k < 0.42:
            self.groups += 1
            name = self.r.choice(["x", "y", "n1"])
            self.names.append(name)
            return f"(?<{name}>" + self.alt(d) + ")"
        if k < 0.52 and self.groups:
            return f"(?({self.r.randint(1, self.groups)})" + self.seq(d) + "|" + self.seq(d) + ")"
        if k < 0.6 and not self.in_absent:
            return self.absent(d)
        kind = self.r.choice(["?:", "?:", "?=", "?!", "?<=", "?<!", "?>", "?i:", "?-i:", "?i", "?x:", "?m:", "?s:"])
        if kind == "?i":
            return "(?i)"
        inner = self.seq(d) if kind in ("?<=", "?<!") else self.alt(d)
        return "(" + kind + inner + ")"

    def text(self):
        return "".join(self.r.choice(TEXT_PIECES) for _ in range(self.r.choice([0, 1, 2, 3, 4, 6, 8])))


FILTERS = ["[match($re; $fl)]", "[match($re; $fl)]", "[match($re; $fl)]", "test($re; $fl)", "[capture($re; $fl)]",
           "[scan($re; $fl)]", "[splits($re; $fl)]", 'sub($re; "<\\(.)>"; $fl)', 'gsub($re; "[\\(.)]"; $fl)']


def make_cases(seed, count):
    rnd = random.Random(seed)
    gen = Gen(rnd)
    cases = []
    for _ in range(count):
        pattern, flags = gen.pattern(), rnd.choice(FLAGS)
        text = gen.text()
        stdin = '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"\n'
        cases.append((["-c", "--arg", "re", pattern, "--arg", "fl", flags], rnd.choice(FILTERS), stdin))
    return cases


def skipped(case):
    opts, _, _ = case
    text = opts[5] + " " + opts[3]
    return next((why for pat, why in SKIP if re.search(pat, text, re.S)), None)


def peak_rss():
    return f", peak RSS {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss >> (20 if sys.platform == 'darwin' else 10)} MB"


if __name__ == "__main__":
    main("regex_diff", make_cases, skipped, peak_rss)
