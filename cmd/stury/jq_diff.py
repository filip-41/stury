#!/usr/bin/env python3
"""Random filters and inputs run through build/stury and jq 1.8.2, reporting where they differ.

    python3 cmd/stury/jq_diff.py [build/stury] [--seed 1] [--cases 20000] [--show 20] [--jq jq]

A seeded grammar makes each case: a small JSON input, a filter of paths, operators, literals, bindings,
reduce/foreach, try, assignments and builtins over it, and a few of jq's options. The same seed makes the
same cases. A case differs when stdout, stderr (stury's `stury:` read as jq's `jq:`) or the exit status
differ; the first --show of them are printed, smallest filter first. A case whose difference docs/cli.md's "Differences from jq" explains (`documented`) is counted apart:
an input outside RFC 8259 that stury refuses where jq read on, and a parse error's message. Under --seq
each text is a record of its own. Not part of `make test`: it needs jq, and a new seed may find what no
test pins yet.
"""

import argparse
import json
import os
import random
import re
import resource
import signal
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jq_suite import as_jq, run_capped

TIMEOUT = 5

KEYS = ["a", "b", "c", "", "é", "a b", "1"]
STRINGS = ["", "a", "abc", "A,b", "é", "1", "x y", "aXbXc", "\t", "😀", "-1.5", "[1]", "null"]
NUMBERS = ["0", "1", "-1", "2", "2.5", "-0", "1.0", "0.1", "1e3", "3", "10", "100000000000000000000", "1e1000", "-7", "1.5e-7"]
PROG_NUMBERS = ["0", "1", "-1", "2", "3", "1.5", "0.5", "10", "-2", "1e2", "1.0", "100000000000000000000"]

ZERO_ARG = """length utf8bytelength not keys keys_unsorted values add any all flatten reverse sort unique min max
tostring tonumber type tojson fromjson ascii_downcase ascii_upcase explode implode to_entries from_entries paths
leaf_paths floor ceil round sqrt fabs abs infinite nan isinfinite isnan isnormal isvalid tostream first last
transpose trim ltrim rtrim @text @json @html @uri @csv @tsv @sh @base64 @base64d @base32 @base32d input_filename
arrays objects iterables booleans numbers strings nulls scalars empty recurse ascii toarray error log exp log10
exp2 log2""".split()
ONE_ARG = """map map_values select sort_by group_by unique_by min_by max_by with_entries walk first last has
contains inside index rindex indices startswith endswith split join ltrimstr rtrimstr test match capture splits
scan any all add path paths getpath delpaths del flatten range error pick in isempty""".split()
TWO_ARG = "limit range setpath sub gsub test match split pow atan2 fmin fmax nth".split()
STRING_ARGS = {"index", "rindex", "indices", "startswith", "endswith", "split", "join", "ltrimstr", "rtrimstr",
               "test", "match", "capture", "splits", "scan", "sub", "gsub"}
REGEXES = ['"a"', '"b+"', '"[0-9]"', '"(?<x>a)"', '"^"', '"$"', '""', '"X"', '","', '"(a)|(b)"', '"\\\\s"']
# Whole terms: idioms the grammar above would rarely write.
IDIOMS = r"""..
[..]
[paths]
[leaf_paths]
[paths(type == "number")]
getpath(["a",0])
[tostream]
fromstream(tostream)
[limit(3; repeat(.))]
[recurse(.[]?; . != null)]
. as [$a] ?// {a: $a} ?// $a | $a
.[]? as [$a, $b] ?// $a | [$a, $b]
def f(g): [g, g]; f(.[]?)
def f($x): $x + 1; f(.[0]?)
def f(g): def h: g; [h]; f(.a?)
[splits(", *"; null)]?
[.[]?] | sort_by(type)
group_by(type)?
unique_by(length)?
[.. | numbers]
del(.. | nulls)?
to_entries?
with_entries(.value |= tostring)?
@json "x\(.)"
@sh "x \(.)"?
@uri "\(.)"
ltrimstr(1)
trimstr("a")?
[range(5; 0; -2)]
add(.[]?)
abs?
significand?
logb?
frexp?
ldexp(.; 2)?
[limit(0; .[]?)]
first(empty)
isempty(.[]?)
getpath(["a"]) |= 3
tojson | fromjson
tostring | fromjson?
input
[inputs]
debug
debug("x")
stderr
error(null)?
halt_error
$__loc__
input_line_number
[.[]?] | implode?
getpath(paths)?
splits("a")?
any(.[]?; . == 1)
all(.[]?; type == "number")
[.[]?] | IN(.[]; 1, "a")
[.[]?] | INDEX(.a?)
to_number?
tojson | test("\\d")
ascii?
@base32d?
[.[]?] | min_by(.), max_by(.)
.[]?[]?
.a?.b?
[.[]? | tostring | ascii_downcase]
getpath([[]])?
try error catch .
try error("x") catch .
try error({}) catch .
(.a? // empty) = 1
.[1:] = ["x"]
.[2:4] |= map(. + 1)?
to_entries? | from_entries
del(.[0, 2])?
del(.[1:])?
delpaths([[0], ["a"]])?
paths(..)?
[splits("")]?
ltrimstr("")
@text "\(1, 2)"
"\(.)\(.)"
$ENV | type
env | type
now | type
[getpath(["a"], [0])?]
limit(2; .[]?)
first(.[]?)
nth(1; .[]?)
until(. == null or (type != "number") or . > 10; . + 3)?
[while(type == "number" and . < 5; . + 1)]
input_filename
splits(1)?
@csv?
@tsv?
tojson | @base64 | @base64d
getpath(["a","b","c"])?
[.[]?] | transpose?
[.[]?] | flatten(1)?
combinations?
[combinations(2)]?
walk(if type == "number" then . + 1 else . end)
walk(numbers)?
[.[]?] | add
[.[]?] | join(",")?
ascii_downcase?
implode?
explode?
[.[]?] | @json
tostream | tojson
getpath(["a"]) = (1, 2)
.. |= (numbers |= . + 1)?
reduce .[]? as [$a] (0; . + 1)
foreach .[]? as {a: $a} (0; . + 1; [$a, .])
label $f | .[]? | if . == 1 then break $f else . end""".split("\n")

OPTIONS = [["-c"], ["-c"], ["-c"], ["-r"], ["-c", "-S"], ["-c", "-s"], ["-c", "-n"], ["-j"], ["--tab"], ["-c", "-a"],
           ["-c", "--arg", "v", "a"], ["-c", "--argjson", "v", "[1,2]"], ["-e", "-c"], ["-c", "--seq"], ["-R"], ["-c", "-R"],
           ["-c", "-Rs"], ["-c", "-Rn"], ["--indent", "1"], ["--indent", "0"], ["-c", "--stream"], ["-c", "--stream", "-n"],
           ["--raw-output0"], ["-c", "-s", "--stream"], ["-C", "-c"], ["-c", "--args"], ["-c", "--jsonargs"],
           ["-c", "--slurpfile", "f", "/dev/null"], ["-c", "--rawfile", "f", "/dev/null"]]


class Gen:
    def __init__(self, rnd):
        self.r = rnd
        self.vars = []

    def pick(self, xs):
        return self.r.choice(xs)

    def json(self, depth=0):
        r = self.r.random()
        if depth < 3 and r < 0.25:
            return "[" + ",".join(self.json(depth + 1) for _ in range(self.r.randrange(4))) + "]"
        if depth < 3 and r < 0.5:
            keys = self.r.sample(KEYS, self.r.randrange(4))
            return "{" + ",".join(f'"{k}":{self.json(depth + 1)}' for k in keys) + "}"
        if r < 0.7:
            return self.pick(NUMBERS)
        if r < 0.9:
            return '"' + self.pick(STRINGS).replace("\\", "\\\\").replace("\t", "\\t") + '"'
        return self.pick(["null", "true", "false"])

    def string(self):
        return '"' + self.pick(STRINGS).replace("\t", "\\t") + '"'

    def literal(self):
        r = self.r.random()
        if r < 0.4:
            return self.pick(PROG_NUMBERS)
        if r < 0.7:
            return self.string()
        if r < 0.8:
            return self.pick(["null", "true", "false"])
        return self.json(1)

    def path(self, depth):
        r = self.r.random()
        steps = [".", ".a", ".b", ".[0]", ".[1]", ".[-1]", ".[]", ".[]?", '.["a"]', ".[1:]", ".[:2]", ".a.b", ".[0].a", ".c?"]
        p = self.pick(steps)
        if depth > 0 and r < 0.15:
            p = f".[{self.expr(depth - 1)}]"
        if r > 0.85:
            p += self.pick([".a", "[0]", "[]", "[]?", "?"])
        return p

    def term(self, depth):
        r = self.r.random()
        if r > 0.95:
            return f"({self.pick(IDIOMS)})"
        if depth <= 0 or r < 0.25:
            return self.pick([self.path(0), self.literal(), self.literal(), "."])
        if r < 0.32:
            return self.path(depth)
        if r < 0.38:
            return f"[{self.expr(depth - 1)}]"
        if r < 0.44:
            k = self.pick(["a", "b", '"a b"', "(.a? // \"k\" | tostring)", "$__loc__"]) if self.r.random() < 0.9 else "a"
            if k == "$__loc__":
                return "{$__loc__}"
            return f"{{{k}: {self.expr(depth - 1)}}}"
        if r < 0.47 and self.vars:
            return "$" + self.pick(self.vars)
        if r < 0.52:
            return f"({self.expr(depth - 1)})"
        return self.call(depth)

    def arg(self, name, depth):
        if name in STRING_ARGS and self.r.random() < 0.8:
            return self.pick(REGEXES) if name in {"test", "match", "capture", "splits", "scan", "sub", "gsub", "split"} else self.string()
        if name in {"range", "limit", "nth"}:
            return self.pick(["0", "1", "2", "3", "-1", "5"])
        if name in {"setpath", "getpath", "delpaths", "has"} and self.r.random() < 0.7:
            return self.pick(['["a"]', "[0]", '["a",0]', "[]", '[["a"]]', '[[0],["b"]]', '"a"', "0"])
        return self.expr(depth - 1)

    def call(self, depth):
        r = self.r.random()
        if r < 0.5:
            return self.pick(ZERO_ARG)
        if r < 0.85:
            f = self.pick(ONE_ARG)
            return f"{f}({self.arg(f, depth)})"
        f = self.pick(TWO_ARG)
        if f in {"sub", "gsub"}:
            return f'{f}({self.pick(REGEXES)}; {self.pick([self.string(), chr(34) + "<\\(.)>" + chr(34), self.expr(depth - 1)])})'
        if f in {"test", "match", "split"}:
            return f'{f}({self.pick(REGEXES)}; {self.pick(["null", chr(34) + "g" + chr(34), chr(34) + "x" + chr(34), chr(34) + "gi" + chr(34)])})'
        if f in {"limit", "range", "nth"}:
            return f"{f}({self.arg(f, depth)}; {self.expr(depth - 1) if f != 'range' else self.arg(f, depth)})"
        if f == "setpath":
            return f"setpath({self.arg(f, depth)}; {self.expr(depth - 1)})"
        return f"{f}({self.expr(depth - 1)}; {self.expr(depth - 1)})"

    def bound(self, depth, make):
        name = self.pick(["x", "y", "z"])
        self.vars.append(name)
        try:
            return make(name)
        finally:
            self.vars.pop()

    def expr(self, depth):
        r = self.r.random()
        if depth <= 0 or r < 0.3:
            return self.term(depth)
        d = depth - 1
        if r < 0.42:
            return f"{self.term(d)} | {self.expr(d)}"
        if r < 0.5:
            return f"{self.term(d)}, {self.expr(d)}"
        if r < 0.62:
            op = self.pick(["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "and", "or", "//"])
            return f"{self.term(d)} {op} {self.term(d)}"
        if r < 0.67:
            els = "" if self.r.random() < 0.3 else f" else {self.expr(d)}"
            return f"if {self.term(d)} then {self.expr(d)}{els} end"
        if r < 0.72:
            return f"try {self.term(d)}" + (f" catch {self.term(d)}" if self.r.random() < 0.5 else "")
        if r < 0.77:
            op = self.pick(["=", "|=", "+=", "-=", "*=", "//=", "|= empty"])
            rhs = "" if op == "|= empty" else " " + self.term(d)
            return f"{self.path(0)} {op}{rhs}"
        if r < 0.82:
            src = self.term(d)
            return self.bound(d, lambda v: f"{src} as ${v} | {self.expr(d)}")
        if r < 0.87:
            src, init = self.term(d), self.term(d)
            return self.bound(d, lambda v: f"reduce {src} as ${v} ({init}; {self.expr(d)})")
        if r < 0.91:
            src, init = self.term(d), self.term(d)
            extract = "" if self.r.random() < 0.4 else f"; {self.expr(d)}"
            return self.bound(d, lambda v: f"foreach {src} as ${v} ({init}; {self.expr(d)}{extract})")
        if r < 0.94:
            return f"{self.term(d)}?"
        if r < 0.96:
            return f"label $out | {self.term(d)} | ., break $out"
        if r < 0.98:
            return f"def f: {self.term(d)}; {self.expr(d)} | f"
        return f"[.[]?] as [$a, $b] | [$a, $b]" if self.r.random() < 0.5 else ". as {a: $a} | $a"


def make_cases(seed, count):
    rnd = random.Random(seed)
    gen = Gen(rnd)
    cases = []
    for _ in range(count):
        opts = rnd.choice(OPTIONS)
        texts = rnd.choice([1, 1, 1, 2])
        # Under --seq each text is a record (RFC 7464), as stury reads one record as one text.
        rs = "\x1e" if "--seq" in opts else ""
        stdin = "".join(rs + gen.json() + "\n" for _ in range(texts))
        if rnd.random() < 0.03:
            stdin = stdin[:rnd.randrange(len(stdin))] + rnd.choice(["", "]", "}", ",", "x", "\\u00", "nul", "1."])
        cases.append((opts, gen.expr(rnd.choice([1, 2, 3, 4])), stdin))
    return cases


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (TIMEOUT, TIMEOUT))


def run(binary, opts, prog, stdin):
    try:
        p = run_capped([binary, *opts, prog], stdin.encode(), TIMEOUT, preexec_fn=limits)
        # RLIMIT_CPU and the wall clock are the same limit; which one stops a runaway first is a race. On a
        # host with less memory than two capped runs, the kernel's OOM killer (a SIGKILL) can win it too.
        if p.returncode in (-signal.SIGXCPU, -signal.SIGKILL):
            return "timeout", b"", b""
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""


def refuse(name):
    raise ValueError(name)


def strict_texts(stdin):
    """Whether stdin is JSON texts as RFC 8259 has them, apart by whitespace (or record separators) or not:
    the grammar stury reads."""
    decoder, space = json.JSONDecoder(parse_constant=refuse), re.compile(r"[ \t\n\r\x1e]*")
    at = space.match(stdin).end()
    while at < len(stdin):
        try:
            _, at = decoder.raw_decode(stdin, at)
        except ValueError:
            return False
        at = space.match(stdin, at).end()
    return True


def documented(stdin, got, want):
    """Which of docs/cli.md's "Differences from jq" explains stury's answer `got` where jq's is `want`, or None."""
    parse_error = lambda err: b"parse error: " in err
    # A parse error's words and position, in a run's message, in `fromjson`'s, or in the error `input` raises.
    unworded = lambda err: re.sub(rb"(parse error: )[^\n]*|(\): )[^\n]*( \(while parsing ')|(\(at <stdin>:\d+\): )[^\n]* at line \d+, column \d+$", rb"\1\2\3\4", err, flags=re.M)
    if not strict_texts(stdin) and parse_error(got[2]) and want[1].startswith(got[1]):
        return "grammar"
    # The same, in a string `fromjson`'s error was caught as.
    caught = lambda out: re.sub(rb'"(?:[^"\\\n]|\\.)*? \(while parsing ', b'"(while parsing ', out)
    if got[0] == want[0] and caught(got[1]) == caught(want[1]) and unworded(got[2]) == unworded(want[2]):
        return "message"
    if got == (want[0], want[1], b"") and re.fullmatch(rb"jq: ignoring parse error: Unfinished abandoned text at EOF at line 1, column 0\n", want[2]):
        return "empty --seq stream"
    return None


def compare(stury, jq, case, parallel=False):
    """None, "documented", or how the case differs; "again" for a timeout met in the parallel pass, which a
    loaded host can cause and a serial rerun settles."""
    opts, prog, stdin = case
    got, want = run(stury, opts, prog, stdin), run(jq, opts, prog, stdin)
    if parallel and "timeout" in (got[0], want[0]):
        return "again"
    # `stderr` leaves no newline before an error message, which as_jq looks for.
    got = (got[0], got[1], re.sub(rb"stury: (?=error \(|parse error)", b"jq: ", as_jq(got[2])))
    if got == want:
        return None
    if documented(stdin, got, want):
        return "documented"
    return f"{' '.join(opts)} {prog!r}\n  stdin {stdin!r}\n  stury: exit {got[0]} out {got[1][:300]!r} err {got[2][:300]!r}\n  jq:    exit {want[0]} out {want[1][:300]!r} err {want[2][:300]!r}"


def main(name="jq_diff", make=make_cases, skipped=lambda case: False, tail=lambda: ""):
    """The command line shared with regex_diff.py: `make` the cases of a seed, run those `skipped` finds no
    reason to leave out, print what differs; `tail` adds to the summary line."""
    ap = argparse.ArgumentParser(description=f"stury against jq on seeded random cases ({name})")
    ap.add_argument("stury", nargs="?", default="build/stury")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cases", type=int, default=20000)
    ap.add_argument("--show", type=int, default=20)
    ap.add_argument("--jq", default="jq")
    a = ap.parse_args()
    cases = make(a.seed, a.cases)
    with ThreadPoolExecutor(os.cpu_count()) as pool:
        results = list(pool.map(lambda c: "skip" if skipped(c) else compare(a.stury, a.jq, c, parallel=True), cases))
    results = [compare(a.stury, a.jq, c) if r == "again" else r for r, c in zip(results, cases)]
    diffs = sorted((r for r in results if r not in (None, "skip", "documented")), key=len)
    for d in diffs[:a.show]:
        print(d)
    print(f"{name} seed {a.seed}: {len(cases)} cases, {results.count('skip')} skipped, {results.count('documented')} documented differences, {len(diffs)} differ{tail()}")
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
