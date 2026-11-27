#!/usr/bin/env python3
"""Differential oracle of the v2 jq frontend against jq 1.8.2.

Run from next/: `python3 tools/jq_oracle.py [--quick] [--only corpus|ported|generated] [--show N] [--class NAME]`.
Each program and input runs through `jq -c` (jq 1.8.2 on PATH) and through v2's library (the `oracle_cases` test of
jq/test, which reads STURY_ORACLE_IN and writes STURY_ORACLE_OUT). Answers compare by value: the outputs in order,
then the error message when both fail, then the compile message when neither compiles. A case whose key is in
jq/divergences.tsv, or whose difference falls in one of the deliberate classes of KNOWN, counts as ledger.

Environment: ODIN (the compiler, default the v2 build), JQ (default `jq`), ORACLE_WRAP (a command prefix for the
build, such as a memory cap), ORACLE_JOBS (jq processes at once).
"""

import argparse
import binascii
import collections
import concurrent.futures
import json
import math
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # next/
CASES = os.path.join(ROOT, "jq", "test", "cases")
LEDGER = os.path.join(ROOT, "jq", "divergences.tsv")
ODIN = os.environ.get("ODIN", "/Users/filip/Projects/Odin-v2/odin")
JQ = os.environ.get("JQ", "jq")
JOBS = int(os.environ.get("ORACLE_JOBS", "8"))
BUILD = os.path.join(ROOT, "build")

# Programs that read what the two runs do not share: the clock, randomness, the process, other inputs.
NOT_COMPARABLE = re.compile(r"\b(now|input|inputs|debug|stderr|halt|halt_error|env|input_filename|input_line_number|get_search_list|localtime|strflocaltime|ltrimstr_)\b|\$ENV|\$__prog")


class Case:
    __slots__ = ("key", "prog", "input", "group", "want_fail")

    def __init__(self, key, prog, input, group, want_fail=False):
        self.key, self.prog, self.input, self.group, self.want_fail = key, prog, input, group, want_fail


def read_suite(name):
    """The cases of a corpus-form file, the way jq's run-tests reads it."""
    lines = open(os.path.join(CASES, name), encoding="utf-8").read().split("\n")
    skip = lambda s: s.strip(" \t") == "" or s.lstrip(" \t").startswith("#")
    out, i, fail = [], 0, False
    while i < len(lines):
        line = lines[i]
        i += 1
        if skip(line):
            continue
        at = i
        if line in ("%%FAIL", "%%FAIL IGNORE MSG"):
            fail = True
            continue
        if fail:
            while i < len(lines) and lines[i] != "":
                i += 1
            out.append(Case(f"{name}:{at}", line, "null", name, True))
            fail = False
            continue
        text = lines[i] if i < len(lines) else "null"
        i += 1
        while i < len(lines) and not skip(lines[i]):
            i += 1
        out.append(Case(f"{name}:{at}", line, text, name))
    return out


def ledger():
    keys = {}
    for line in open(LEDGER, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            f = line.rstrip("\n").split("\t")
            keys[f[0]] = f[1]
    return keys


# ---- generated cases

VALUES = [
    "null", "true", "false", "0", "1", "-1", "2", "3", "0.5", "1.5", "-2.5", "1e3", "3.0", "100000000000000000000",
    '""', '"a"', '"abc"', '"a,b"', '"A b"', '"1"', '"é"', '"2015-03-05T23:51:47Z"', "[]", "[1,2,3]", "[3,1,2]",
    '["a","b"]', "[[1,2],[3,4]]", '[null,1,"a"]', "[1,[2,[3]]]", "[0,1,1,2]", "{}", '{"a":1}', '{"a":1,"b":2}',
    '{"a":[1,2],"b":{"c":3}}', '[{"a":1},{"a":2}]', '{"a":null}',
]
SMALL = ["null", "true", "0", "2", "-1.5", '""', '"abc"', "[]", "[3,1,2]", '[[1,2],[3]]', '[null,"a"]', "{}", '{"a":1,"b":[1,2]}',
         '[{"a":1},{"a":2}]', '"a,b"', "[1,2,3,4]"]
ARGS = ["null", "1", "2", "-1", "0.5", '"a"', '""', '","', "[1]", '["a"]', '{"a":1}', ".", ".[0]", ".a", "empty",
        "(1,2)", ". + 1", "not", "type", "tostring", "length", ".[]"]
ARGS_SMALL = ["1", '"a"', "[1]", ".", ".a", "empty", "(1,2)", "length", "not"]
SKIP_BUILTINS = {
    "input", "inputs", "debug", "stderr", "now", "halt", "halt_error", "input_filename", "input_line_number", "env",
    "get_search_list", "localtime", "strflocaltime", "repeat", "until", "while", "recurse", "recurse_down", "builtins",
    "ltrimstr_", "getpath/1", "limit", "range", "splits", "combinations", "walk", "input_line_number", "modulemeta",
    "get_prog_origin", "get_jq_origin", "$__loc__", "ldexp", "scalb", "scalbln", "nearbyint", "significand", "drem",
    "gamma", "lgamma", "tgamma", "lgamma_r", "frexp", "modf", "logb", "ceil", "floor",
}
# A builtin that is not infinite on any argument above, yet worth running: range and limit on small numbers only.
EXTRA = [
    'limit(2; .[]?)', 'limit(0; 1, 2)', 'limit(-1; 1, 2)', '[range(3)]', '[range(1; 4)]', '[range(0; 10; 3)]',
    '[range(5; 0; -2)]', '[range(0; 1; 0.3)]', '[range(.)]?', '[range(.; 3)]?',
    '[recurse(if . < 3 then . + 1 else empty end)]?', '[recurse(.[]?)]', '[recurse(.[]?; . != 1)]',
    '[while(length > 0; .[1:])]?', '[repeat(empty)]', '[until(. > 3; . + 1)]?',
    'walk(if type == "number" then . + 1 else . end)', 'walk(.)', '[splits("a")]?', '[splits(",")]?', 'ceil?',
    'floor?', 'round?', 'sqrt?', 'pow(.; 2)?', 'log?', 'exp?', '[combinations]?', '[combinations(2)]?',
    'input_line_number', '[.[]?] | length', 'ltrimstr(1)', 'rtrimstr(1)', 'ltrimstr("a")', 'rtrimstr("c")', 'trim?',
    'ltrim?', 'rtrim?', 'tojson | fromjson', 'tostring | tonumber?', '[.[]?|tostring]', '@text', '@json', '@csv?',
    '@tsv?', '@html', '@uri', '@sh?', '@base64', '@base64d?', '@base32', '@base32d?', '"x\\(.)y"', '@json "v=\\(.)"',
    '@csv "\\(.)"?', '@sh "echo \\(.)"?', '@uri "\\(.)"', 'ascii_downcase?', 'ascii_upcase?', 'explode?', 'implode?',
    '[.[]?] | implode?', 'ascii?', 'tojson', 'fromjson?', 'todate?', 'fromdate?', 'mktime?', 'gmtime?',
    'gmtime | mktime?', 'gmtime | todate?', 'strftime("%Y-%m-%dT%H:%M:%SZ")?', 'strptime("%Y-%m-%dT%H:%M:%SZ")?',
    'strptime("%Y-%m-%dT%H:%M:%SZ") | mktime?', 'dateadd("seconds"; 1)?', 'todateiso8601?', 'fromdateiso8601?',
    'dateadd?', 'getpath(["a"])', 'getpath(["a","b"])?', 'getpath([0])?', 'setpath(["a"]; 1)?', 'setpath([0]; 1)?',
    'setpath([]; 1)', 'delpaths([["a"]])?', 'delpaths([[0]])?', 'delpaths([[]])', 'to_entries?', 'from_entries?',
    'with_entries(.)?', 'with_entries(.value |= . + 1)?', 'paths', '[paths]', '[paths(type == "number")]',
    '[leaf_paths]', 'path(..)', '[path(..)]', '[..]', '[.. | numbers]', 'pick(.a)?', 'pick(.[0])?', 'pick(.a.b)?',
    'pick(first)?', 'pick(.[1:])?', 'debug("x")?', 'scan("a")?', '[scan("[a-c]")]?', 'test("a")?', 'match("a")?',
    '[match("a|b"; "g")]?', 'capture("(?<x>a)")?', 'sub("a"; "b")?', 'gsub("a"; "b")?', 'gsub(""; "-")?',
    'gsub("(?<x>a)"; "[\\(.x)]")?', 'split(", ")?', 'split("a"; null)?', 'split("a"; "g")?', 'ascii_downcase',
    'tojson | length', 'utf8bytelength?', '[.[]?] | sort_by(.)?', 'group_by(.)?', 'unique_by(.)?', 'min_by(.)?',
    'max_by(.)?', 'sort_by(.a)?', 'group_by(.a)?', 'unique_by(length)?', 'min_by(.a)?', 'add?', 'add(.[]?)',
    'add(empty)', 'any?', 'all?', 'any(.)?', 'all(.)?', 'any(.[]?; . == 1)', 'all(.[]?; . == 1)', 'flatten?',
    'flatten(1)?', 'flatten(-1)?', 'tojson|tojson', '@json|fromjson', 'env|type', '$ENV|type', 'input_filename',
    'splits("a";"g")?', 'ltrimstr("a")?', 'tostring', 'tonumber?', 'toarray', 'have_literal_numbers', 'have_decnum',
    'abs?', 'trimstr("a")?', 'ltrimstr("a") | rtrimstr("c")', 'getpath(["a"]) as $x | $x', 'limit(3; repeat(1))',
    'first(range(10; 0; -1))', 'isempty(empty)', 'isempty(1, error)', 'error?', 'error(null)?', 'try error catch .',
    'try error("x") catch .', 'try error({a:1}) catch .', '[.[]?|try error catch .]',
    '(.. | select(type == "number")) |= . + 1', '(.[]? | select(. == 1)) = 9', 'tostream', '[tostream]',
    'fromstream(tostream)', '[.[]?] | tostream', 'truncate_stream(1; tostream)?', '[limit(3; .[]?)]', 'first?',
    'last?', 'nth(1)?', 'nth(1; .[]?)', '[.[]?] | first', '[.[]?] | last', 'indices(1)?', 'indices("a")?',
    'indices([1,2])?', 'index("a")?', 'rindex("a")?', 'inside([1,2,3])?', 'contains("a")?', 'contains([1])?',
    'contains({a:1})?', 'splits("a")?', 'getpath(["a"]) // 0', '.a // 0', '.[0]? // 0', '(.a, .b) // 3',
    'first(.a, .b) // 3', '[.[]? // 3]', '[(false, null, 1) // 3]', '[(false, null) // 3]',
    'label $f | 1, break $f, 2', '[label $f | .[]? | if . == 2 then break $f else . end]',
    'reduce .[]? as $x (0; . + $x)', 'foreach .[]? as $x (0; . + $x)', 'foreach .[]? as $x (0; . + $x; [., $x])',
    'reduce .[]? as [$a, $b] (0; . + $a)', '. as [$a, $b] | [$a, $b]', '. as {a: $a} | $a', '. as {$a} | $a',
    '. as [$a] ?// $a | [$a]', '. as {a: [$x]} ?// {a: $x} | $x', '[.[]? as [$a] ?// $a | $a]', 'def f: 1; f',
    'def f(x): x * 2; f(3)', 'def f($x): $x + 1; f(2)', 'def f(g): [g]; f(1, 2)', '[.[]?] | map(. + 1)?',
    'map_values(. + 1)?', 'map_values(empty)?', 'map(select(. == 1))?', 'to_entries | from_entries?', 'keys?',
    'keys_unsorted?', 'values', 'nulls', 'booleans', 'numbers', 'strings', 'arrays', 'objects', 'iterables',
    'scalars', 'length?', 'not', 'type', 'infinite', '-infinite', 'nan | isnan', 'isinfinite?', 'isnormal?',
    '[infinite, -infinite, nan] | map(tojson)', 'infinite | tostring', 'nan | tostring', '[nan] | tojson',
    '[nan] | sort', 'nan < 1', '[nan, 1] | min', 'nan == nan', '[nan] | index(nan)?', '{} | .a.b.c',
    '{} | .a.b.c = 1', 'null | .[1] = 1', 'null | .[-1]?', '[1] | .[-2] = 1?', 'try ([1] | .[-2] = 1) catch .',
    '[1,2,3] | .[1:] = [9]', '[1,2,3] | .[:1] |= map(. + 1)', '[1,2,3] | del(.[0,2])', '[1,2,3] | del(.[1:])',
    '[1,2,3] | to_entries', '[1,2,3] | .[1.5]', '[1,2,3] | .[null]?', '[1,2,3] | .["a"]?', '{"a":1} | .["a"]',
    '{"a":1} | .a?', '{"a":1} | .[0]?', '"abc" | .[1:2]', '"abc" | .[1:]', '"abc" | .[:-1]', '"abc" | .[0]?',
    'null | .[1:2]', '[1,2,3] | .[1:null]', '[1,2,3] | .[null:2]', '[1,2,3] | .[1.2:2.5]', '$__loc__',
    'tojson | test("1")', 'ascii', 'getpath(["a", 0])?', '[paths(..)]', '[getpath(paths)]', '[.. | scalars]', '@sh',
    'min_by(length)?', 'limit(1; .[]?)', 'until(true; 1)', '[limit(3; 1, 2, 3, 4)]', 'first(empty)', '[first(empty)]',
    'nth(5; 1, 2)', '[nth(5; 1, 2)]', 'try nth(-1; 1, 2) catch .', '(.a, .b) = 9', '(.a, .b) |= . + 1', '.a += 1',
    '.a -= 1', '.a *= 2', '.a /= 2', '.a %= 2', '.a //= 7', '.a |= empty', '.[]? |= empty', '.[0]? |= . + 1',
    '.[]? += 1', '.. |= .', '..? |= (numbers |= . + 1)?', 'to_entries[]?', 'with_entries(select(.value))?',
    '[.[]?] | transpose?', 'tojson|ascii_downcase', '[.[]?] | join(",")?', 'join(",")?', '[.[]?] | join(1)?',
    '[.[]?] | min, max', '[.[]?] | add / length', '[.[]?] | unique', '[.[]?] | reverse', 'reverse?', '[.[]?] | sort',
    'sort?', '[.[]?] | group_by(. % 2)?', 'any(true)', 'all(false)', '[splits("")]?', 'getpath(["a"])?',
    'limit(1; error)?', '[limit(0; error)]', '[.[]?] | .[length]', '[.[]?] | .[length - 1]', 'bsearch(1)?',
    'bsearch(2)?', '[.[]?] | bsearch(0)?', '[.[]?] | bsearch(5)?', '@uri "\\(.)"?', '"\\(1;2)"?', '"a" * 3?', '. * 0',
    '. * 2', '. * -1', '. * 0.5', '. * 1e3?', '. / 0?', '. % 0?', '[. % 3?]', '-.?', '- (. + 1)?', '. + null',
    'null + .', '. - 1?', '1 - .?', '[.] | .[0] / 2?', '(. / 2)?', '. == .', '. != .', '. < .', '. <= .', '. > .',
    '. >= .', '[. , .] | sort', '[., null] | sort', '[., 1, "a", [], {}, null, true, false] | sort',
    '[., 1, "a", [], {}, null, true, false] | sort_by(type)', '[., 1] | min', '[., 1] | max', 'length',
]
DEEP = [
    "def f: if . < 100000 then (.+1|f)+1 else . end; 0|f",
    "def f: if . < 100000 then (.+1, empty)|f else . end; 0|f",
    "def f: if . == 0 then 0 else (. - 1 | f) + 1 end; 100000 | f",
    'reduce range(9999) as $i (0; [.]) | walk(if type == "number" then . + 1 else . end) | [paths] | length',
    '[range(100000)] | reduce .[] as $x (null; [$x, .]) | [paths] | length',
    '[limit(100000; repeat(1))] | length',
    'last(range(1000000))',
]
OPS = ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "and", "or", "//"]
PATHS = [".", ".a", ".[0]", ".[-1]", ".[1:]", ".[:1]", ".[]", ".[]?", "..", ".a.b", ".[0].a", ".a[]?", ".[\"a\"]", ".a?", ".[0]?",
         "first", "last", "select(type == \"number\")", "(.a, .b)", "getpath([\"a\", \"b\"])", ".a // 5", "if type == \"array\" then .[0] else .a end", ".[1,2]", ".[1:][0]?", "recurse", "limit(1; .[]?)", "empty"]
UPDATES = ["path({P})", "[path({P})]", "del({P})", "{P} = 9", "{P} |= . + 1", "{P} += 1", "{P} |= empty", "{P} //= 3", "[{P}]", "pick({P})", "to_entries", "[paths]", "[leaf_paths]",
           "delpaths([path({P})])", "try ({P} |= error) catch .", "{P} |= [.]", "{P} as $x | $x", "[{P} | tojson]", "paths(type == \"number\")", "reduce path({P}) as $p (.; setpath($p; 0))"]
PATH_VALUES = ["null", "[]", "[1,2,3]", "[[1],[2,3]]", '{"a":1}', '{"a":{"b":2},"c":[3]}', '[{"a":1},{"b":2}]', '{"a":null}', '"abc"', "1", "[null,[],{}]", "[1,2,3,4,5]"]


def generated(quick):
    cases = []

    def add(group, prog, value):
        cases.append(Case(f"{group}:{len(cases)}", prog, value, group))

    names = json.loads(subprocess.run([JQ, "-nc", "[builtins]"], capture_output=True, text=True).stdout)[0]
    values = VALUES[::3] if quick else VALUES
    args = ARGS[::3] if quick else ARGS
    small = SMALL[::3] if quick else SMALL
    small_args = ARGS_SMALL[::2] if quick else ARGS_SMALL
    for n in names:
        name, _, arity = n.rpartition("/")
        arity = int(arity)
        if name.startswith("_") or name in SKIP_BUILTINS or n in SKIP_BUILTINS:
            continue
        if arity == 0:
            for v in values:
                add("builtin0", name, v)
        elif arity == 1:
            for a in args:
                for v in small:
                    add("builtin1", f"{name}({a})", v)
        elif arity == 2:
            for a in small_args:
                for b in small_args:
                    for v in small[::2]:
                        add("builtin2", f"{name}({a}; {b})", v)
        elif arity == 3:
            for a in small_args[::2]:
                for b in small_args[::2]:
                    for c in small_args[::3]:
                        add("builtin3", f"{name}({a}; {b}; {c})", small[2])
                        add("builtin3", f"{name}({a}; {b}; {c})", small[-2])
    add("builtins", "builtins | sort", "null")
    seen = set()
    for p in EXTRA:
        if p in seen:
            continue
        seen.add(p)
        for v in (small if quick else VALUES):
            add("extra", p, v)
    for p in DEEP:
        add("deep", p, "null")
    for op in OPS:
        for a in (VALUES[::2] if quick else VALUES):
            for b in (VALUES[1::2] if quick else VALUES):
                add("operator", f"{a} {op} {b}", "null")
    for a in VALUES:
        add("operator", f"-({a})", "null")
        add("operator", f"[{a}] | .[0] as $x | [$x, ($x | not), ($x // 1)]", "null")
        for i in ("0", "-1", "1.5", '"a"', "null", "[0]", "[1,2]", "{}", '{"start":1}', "true"):
            add("index", f".[{i}]", a)
            add("index", f".[{i}]?", a)
            add("index", f"try .[{i}] catch .", a)
            add("index", f".[{i}] = 1", a)
            add("index", f"try (.[{i}] |= . ) catch .", a)
            add("index", f"del(.[{i}])", a)
        for lo, hi in (("1", "2"), ("-1", ""), ("", "-1"), ("null", "1"), ('"a"', "1"), ("1.5", "2.5"), ("", "")):
            add("slice", f".[{lo}:{hi}]", a)
            add("slice", f"try (.[{lo}:{hi}] = [9]) catch .", a)
            add("slice", f"try del(.[{lo}:{hi}]) catch .", a)
    for v in PATH_VALUES:
        for p in PATHS:
            for u in UPDATES:
                add("update", u.replace("{P}", p), v)
    return cases


# ---- running both sides

def tokens_hex(s):
    return binascii.hexlify(s.encode("utf-8", "surrogatepass")).decode()


def run_v2(cases, workdir):
    os.makedirs(workdir, exist_ok=True)
    src, dst = os.path.join(workdir, "in.txt"), os.path.join(workdir, "out.txt")
    with open(src, "w") as f:
        for c in cases:
            f.write(f"{tokens_hex(c.prog)} {tokens_hex(c.input)}\n")
    env = dict(os.environ, STURY_ORACLE_IN=src, STURY_ORACLE_OUT=dst)
    if os.path.exists(dst):
        os.remove(dst)
    cmd = os.environ.get("ORACLE_WRAP", "").split() + [
        ODIN, "test", "jq/test", "-o:minimal", f"-collection:stury={ROOT}", "-define:ODIN_TEST_NAMES=jq_tests.oracle_cases",
        "-define:TEST_TIMEOUT_SECONDS=3000", f"-out:{BUILD}/oracle-jq",
    ]
    os.makedirs(BUILD, exist_ok=True)
    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    if not os.path.exists(dst):
        sys.exit("v2 runner failed:\n" + r.stdout[-2000:] + r.stderr[-2000:])
    out = []
    for line in open(dst, encoding="utf-8").read().split("\n")[: len(cases)]:
        toks = []
        for t in line.split():
            toks.append((t[0], bytes.fromhex(t[2:]).decode("utf-8", "replace")))
        out.append(toks)
    return out


def parse_json(text):
    return json.loads(text, parse_constant=lambda s: float("nan"))


JQ_ERROR = re.compile(r"^jq: error \(at [^)]*\)( \(not a string\))?: ", re.M)


def run_jq(c):
    """jq's answer as the tokens of the v2 runner, or None when it cannot be had (a timeout)."""
    prog = c.prog
    args = [JQ, "-c", "-L", os.path.join(CASES, "modules"), "--", prog]
    try:
        r = subprocess.run(args, input=(c.input + "\n").encode(), capture_output=True, timeout=10, env=dict(os.environ, TZ="UTC"))
    except subprocess.TimeoutExpired:
        return None
    out, err = r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    toks = []
    if r.returncode == 3:
        msgs = [l for l in err.split("\n") if l.startswith("jq: error:")]
        return [("c", (msgs[-1] if msgs else err).replace(ROOT + "/", ""))]
    for line in out.split("\n"):
        if line:
            toks.append(("o", line))
    if r.returncode == 5:
        m = JQ_ERROR.search(err)
        toks.append(("e", err[m.end():].rstrip("\n") + (" (not a string)" if m.group(1) else "") if m else err))
    elif r.returncode not in (0, 5):
        toks.append(("x", f"status {r.returncode}: {err}"))
    return toks


sys.setrecursionlimit(100000)


def same_value(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b or (isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b))
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same_value(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same_value(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def nearly_equal(a, b):
    """Whether two outputs lists are the same numbers but for a few units in the last place."""
    if len(a) != len(b):
        return False
    close = False
    for x, y in zip(a, b):
        if isinstance(x, float) and isinstance(y, float) and x != y and abs(x - y) <= 1e-12 * max(abs(x), abs(y)):
            close = True
        elif not same_value(x, y):
            return False
    return close


def compare(mine, theirs, prog=""):
    """The difference between v2's tokens and jq's: None when they agree, else (kind, detail)."""
    if theirs is None:
        return None
    mine = [t for t in mine if t[0] != "h"]
    if any(t[0] == "l" for t in mine):
        return ("leak", "")
    if any(t[0] == "i" for t in mine):
        return ("input", mine[0][1])
    if mine and mine[0][0] == "c" or theirs and theirs[0][0] == "c":
        a = mine[0][1] if mine and mine[0][0] == "c" else None
        b = theirs[0][1] if theirs and theirs[0][0] == "c" else None
        if a is None or b is None:
            return ("compile", f"v2 {a!r}, jq {b!r}")
        return None if a == b else ("compile-message", f"v2 {a!r}, jq {b!r}")
    mo = [t[1] for t in mine if t[0] == "o"]
    jo = [t[1] for t in theirs if t[0] == "o"]
    me = [t[1] for t in mine if t[0] == "e"]
    je = [t[1] for t in theirs if t[0] == "e"]
    try:
        mv, jv = [parse_json(x) for x in mo], [parse_json(x) for x in jo]
        values_agree = len(mv) == len(jv) and all(same_value(x, y) for x, y in zip(mv, jv))
    except (ValueError, RecursionError):
        values_agree = mo == jo
    if not values_agree and prog == "builtins | sort" and not me and not je:
        extra, missing = set(mv[0]) - set(jv[0]), set(jv[0]) - set(mv[0])
        if not missing:
            return ("builtins-extra", f"{len(extra)} names beyond jq: {sorted(extra)}")
        return ("builtins-missing", f"v2 lacks {sorted(missing)}")
    if not values_agree:
        if not me and not je and nearly_equal(mv, jv):
            return ("last-digit", f"v2 {mo}, jq {jo}")
        return ("outputs", f"v2 {mo} {me}, jq {jo} {je}")
    if bool(me) != bool(je):
        return ("error-presence", f"v2 {me}, jq {je}")
    if me and me[0] != je[0]:
        return ("error-message", f"v2 {me[0]!r}, jq {je[0]!r}")
    return None


# Deliberate differences that carry no ledger row of their own because they have no corpus line: each is a ledger kind
# of divergences.tsv given as a test of the case and the difference.
def known(c, kind, detail):
    if kind == "outputs" and (re.search(r"\d{17,}|e\+?\d{3,}|1\.7976931348623157e\+308", detail, re.I) or re.search(r"\d{17,}", c.prog)):
        return "better: exact integers and decimal overflow"
    if kind in ("outputs", "error-message") and re.search(r"\d[eE][+-]?\d|\d\.\d*0\b", c.prog + c.input) and re.search(r"\dE[+-]?\d|\d\.\d*0\b|E%2B", detail):
        return "better: a decimal literal is a double, where jq keeps its digits"
    if kind == "error-message" and re.search(r"\((?:\d+\.0+|[\d.]+E[+-]?\d+)\)", detail):
        return "better: a decimal literal is a double"
    if "containment checked" in detail and "boolean" in detail:
        return "better: contains takes true and false for one type"
    if kind in ("error-message", "error-presence") and "Invalid limit: not a number" in detail:
        return "better: a count that is no number is refused as such, where jq fails on its arithmetic or says the count is negative"
    if kind == "error-message" and "cannot be sorted, as it is not an array" in detail and re.search(r"cannot be sorted, as they are not both arrays|cannot be iterated over", detail):
        return "better: sorting, grouping, min and max of a value that is no array name that value, where jq names the key list it made too"
    if kind == "error-message" and re.search(r"v2 [\"']\d+:\d+: ", detail):
        return "reader: fromjson's parse errors are the JSON reader's messages, with the line and column first"
    if kind == "error-message" and re.search(r"v2 .*\d{17,}", detail):
        return "better: exact integers"
    if kind == "outputs" and re.search(r"\d[eE][+-]?\d", c.input) and not re.search(r"\d[eE][+-]?\d", c.prog):
        return "better: a decimal literal is a double, where jq keeps its text"
    if "base32" in c.prog and ("base32" in detail and "not a valid format" in detail or "@base32d" in c.prog):
        return "platform: the jq build the oracle runs has no @base32 and @base32d"
    if kind == "outputs" and c.input == "[]" and ("1900-01-00" in detail or "invalid gmtime" in detail or "-2209075200" in detail):
        return "better: an empty broken-down time is the year 1900, day 0, normalised, where jq prints day 00 and mktime refuses it"
    if kind == "outputs" and re.match(r"\[-?\d{1,3}[,\]]", c.input) and re.search(r"mktime|strftime|todate", c.prog):
        return "platform: years before 1900, which macOS's strftime pads to four digits and its timegm refuses, as glibc's do not"
    if kind == "outputs" and "strptime" in c.prog:
        return "platform: strptime leaves the weekday and day of the year at jq's sentinels 8 and 367 as glibc does, where macOS computes them"
    if kind == "builtins-extra":
        return "beyond: stury's own builtins and leaf_paths"
    if kind == "last-digit":
        return "platform: the libm's last digit"
    if kind == "compile" and "is not defined" in detail and "v2 None" in detail:
        return "beyond: a builtin stury has and jq 1.8.2 lacks"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="a third of the generated cases")
    ap.add_argument("--only", choices=["corpus", "ported", "generated"], action="append")
    ap.add_argument("--show", type=int, default=3, help="examples shown per class")
    ap.add_argument("--class", dest="cls", help="show every case of this class")
    ap.add_argument("--unique", action="store_true", help="with --class, one case per program")
    ap.add_argument("--workdir", default=os.path.join(BUILD, "oracle"))
    a = ap.parse_args()
    only = set(a.only or ["corpus", "ported", "generated"])
    cases = []
    if "corpus" in only:
        for name in ("jq.test", "onig.test"):
            cases += read_suite(name)
    if "ported" in only and os.path.exists(os.path.join(CASES, "ported.test")):
        cases += read_suite("ported.test")
    if "generated" in only:
        cases += generated(a.quick)
    cases = [c for c in cases if not NOT_COMPARABLE.search(c.prog)]
    keys = ledger()
    print(f"{len(cases)} programs", file=sys.stderr)
    with concurrent.futures.ThreadPoolExecutor(JOBS) as pool:
        jq_future = pool.map(run_jq, cases)
        mine = run_v2(cases, a.workdir)
        theirs = list(jq_future)
    counts = collections.Counter()
    classes = collections.defaultdict(list)
    reasons = collections.Counter()
    for c, m, t in zip(cases, mine, theirs):
        if t is None:
            counts["jq timed out"] += 1
            continue
        d = compare(m, t, c.prog)
        if d is None:
            counts["agree"] += 1
            continue
        if d[0] == "input":
            counts["input refused"] += 1  # NaN and Infinity literals: the JSON reader's, not the frontend's
            continue
        why = keys.get(c.key) or known(c, *d)
        if why:
            counts["ledger"] += 1
            reasons[why if not keys.get(c.key) else "corpus ledger row"] += 1
            continue
        counts["differ"] += 1
        classes[(c.group, d[0])].append((c, d[1]))
    print(f"programs {len(cases)}, agreeing {counts['agree']}, ledger {counts['ledger']}, differing {counts['differ']}, input refused {counts['input refused']}, jq timed out {counts['jq timed out']}")
    for why, n in reasons.most_common():
        print(f"  ledger {n:5}  {why}")
    for (group, kind), items in sorted(classes.items(), key=lambda x: -len(x[1])):
        if a.cls and a.cls != "all" and a.cls != f"{group}/{kind}":
            continue
        print(f"\n{group}/{kind}: {len(items)}")
        shown, seen = [], set()
        for c, detail in items:
            if a.unique and c.prog in seen:
                continue
            seen.add(c.prog)
            shown.append((c, detail))
        for c, detail in shown if a.cls else shown[: a.show]:
            print(f"  {c.key}  {c.prog!r}  input {c.input}\n      {detail[:400]}")
    return 1 if counts["differ"] else 0


if __name__ == "__main__":
    sys.exit(main())
