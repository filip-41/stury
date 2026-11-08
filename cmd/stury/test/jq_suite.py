#!/usr/bin/env python3
"""jq 1.8.2's own test suites, and stury's command line cases, run through build/stury.

    python3 cmd/stury/test/jq_suite.py [build/stury] [--diff] [--record]

Each case of jq-1.8.2/jq.test and onig.test (jq's tests/ at tag jq-1.8.2) runs as `stury -L modules -c PROGRAM` with
its input line on stdin, and passes as under `jq --run-tests`: each output equals the expected value, numbers compared
as decimals, with nothing left over; a `%%FAIL` program fails to compile (exit 3) with the first line of its last
`jq: error` message. cli.tsv runs whole command lines and requires jq's exit status, stdout and stderr byte for byte,
or stury's own after them where docs/cli.md's "Differences from jq" says stury reads its input by its own grammar
(DIFFERS is the same for jq.test); `--record` writes jq's from the `jq` on PATH. --diff also runs every case through
jq 1.8.2 and requires the same answer, with `stury:` read as `jq:`. A host with no pseudo-terminal, Windows and
ThreadSanitizer skip the cases they cannot run and say so. The cases run on a thread pool, the report in case order.
"""

import argparse
import functools
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

from harness import as_jq, run_capped

try:
    import pty
except ImportError:  # Windows
    pty = None

HERE = os.path.dirname(os.path.abspath(__file__))
SUITE = os.path.join(HERE, "jq-1.8.2")
# Seconds a case may take; STURY_TEST_TIMEOUT raises it for a sanitized build (make test-asan).
TIMEOUT = float(os.environ.get("STURY_TEST_TIMEOUT", "10"))
# The sanitizer a build was made with, `address` or `thread` (make test-asan, test-tsan), or empty.
SANITIZER = os.environ.get("STURY_SANITIZER", "")
sys.setrecursionlimit(100000)
# Cases running at once: one worker per core with each child allowed MEM_CAP_MB would starve the cases of wall time.
MAX_WORKERS = min(8, os.cpu_count() or 1)


# jq's tests/modules, which jq's suite runs with as `-L`; not part of jq-1.8.2/, so remade from what the
# module cases of jq.test require of it.
MODULE_DIR = os.path.join(HERE, "modules")

def parse_suite(path):
    """jq's test file as cases, read the way jq's run-tests reads it: blank and `#` lines between tests,
    `%%FAIL [IGNORE MSG]` before a program that must not compile (then its message, then lines up to a
    blank one), otherwise the program, one input line and the expected outputs up to a blank or `#` line."""
    lines = open(path, encoding="utf-8", errors="surrogateescape").read().split("\n")
    skip = lambda s: s.lstrip(" \t") == "" or s.lstrip(" \t").startswith("#")
    cases, i, fail = [], 0, None
    while i < len(lines):
        line = lines[i]
        i += 1
        if skip(line):
            continue
        if line in ("%%FAIL", "%%FAIL IGNORE MSG"):
            fail = "ignore" if line.endswith("MSG") else "msg"
            continue
        case = {"file": os.path.basename(path), "line": i, "prog": line, "fail": fail}
        if fail:
            case["msg"] = lines[i] if i < len(lines) else ""
            while i < len(lines) and lines[i] != "":
                i += 1
        else:
            case["input"] = lines[i] if i < len(lines) else ""
            i += 1
            case["want"] = []
            while i < len(lines) and not skip(lines[i]):
                case["want"].append(lines[i])
                i += 1
        fail = None
        cases.append(case)
    return cases


def parse_cli(path):
    """cli.tsv: area, then as JSON the arguments, stdin, files and, once recorded, jq's exit status,
    stdout and stderr. The arguments may be {"env": {NAME: VALUE}, "args": [...]}, to run with those
    variables set, and {"stdout": "closed", "args": [...]} to run with no stdout open. An area starting with `!`
    marks a case too deep for ThreadSanitizer's stack: it runs everywhere else, and the sanitizer report names it
    as not run."""
    cases = []
    for n, row in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if not row or row.startswith("#"):
            continue
        area, *cols = row.split("\t")
        slow = area.startswith("!")
        if slow:
            area = area[1:]
        args, stdin, files, *want = [json.loads(c) for c in cols]
        env, closed = {}, False
        if isinstance(args, dict):
            env, closed, args = args.get("env", {}), args.get("stdout") == "closed", args["args"]
        cases.append({"line": n, "area": area, "args": args, "env": env, "closed": closed, "stdin": stdin, "files": files, "want": want, "row": row, "slow": slow})
    return cases


def run_cli(binary, case):
    """The case's command line in a scratch directory holding its files: exit status, stdout, stderr. `$DIR`
    in an argument or a variable is that directory, and it (or its real path) in the output reads `$DIR`; a
    variable set to null is unset."""
    enc = lambda s: s.encode("utf-8", "surrogateescape")
    with tempfile.TemporaryDirectory() as d:
        for name, content in case["files"].items():
            os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
            with open(os.path.join(d, name), "wb") as f:
                f.write(enc(content))
        args = case["args"] if binary != "jq" else jq_args(case["args"])
        args = [a.replace("$DIR", d) for a in args]
        env = {**os.environ, **{k: v.replace("$DIR", d) for k, v in case["env"].items() if v is not None}}
        for k in [k for k, v in case["env"].items() if v is None]:
            env.pop(k, None)
        real = enc(os.path.realpath(d))
        try:
            closing = ["/bin/sh", "-c", 'exec "$0" "$@" >&-'] if case["closed"] else []
            p = run_capped(closing + [binary] + args, enc(case["stdin"]), TIMEOUT, cwd=d, env=env)
            unreal = lambda b: b.replace(real, b"$DIR").replace(enc(d), b"$DIR")
            return p.returncode, unreal(p.stdout), unreal(p.stderr)
        except subprocess.TimeoutExpired:
            return "timeout", b"", b""


def record_cli(path):
    """Writes jq's answers into cli.tsv."""
    dec = lambda b: b.decode("utf-8", "surrogateescape")
    lines = open(path, encoding="utf-8").read().split("\n")
    cases = parse_cli(path)
    with ThreadPoolExecutor(MAX_WORKERS) as pool:
        answers = list(pool.map(lambda case: run_cli("jq", case), cases))
    for case, (code, out, err) in zip(cases, answers):
        cols = case["row"].split("\t")
        if case["want"] and case["want"][0] is None:
            continue
        # A row whose answer is unchanged keeps its bytes, however its strings are escaped.
        if case["want"][:3] != [code, dec(out), dec(err)]:
            cols[4:7] = [json.dumps(code), json.dumps(dec(out)), json.dumps(dec(err))]
            lines[case["line"] - 1] = "\t".join(cols)
    open(path, "w", encoding="utf-8").write("\n".join(lines))


def ptys_here():
    """Whether this host can open a pseudo-terminal. A sandbox or a minimal container without /dev/pts
    cannot: the terminal cases are then skipped and said so, not failed."""
    if pty is None:
        return False
    try:
        master, slave = pty.openpty()
    except OSError:
        return False
    os.close(master)
    os.close(slave)
    return True


def run_tty(binary, args, stdin_tty, stdout_tty, feed, env={}):
    """`binary args` with stdin and stdout each a terminal or a pipe, and the variables `env` set: exit
    status, stdout, stderr."""
    master, slave = pty.openpty()
    p = subprocess.Popen([binary] + args, stdin=slave if stdin_tty else subprocess.PIPE,
                         stdout=slave if stdout_tty else subprocess.PIPE, stderr=subprocess.PIPE,
                         env={**os.environ, **env})
    # The slave stays open until the master is read: macOS drops a terminal's unread output once its last
    # slave descriptor closes.
    if stdin_tty:
        os.write(master, feed)
    else:
        p.stdin.write(feed)
        p.stdin.close()
    try:
        code = p.wait(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        p.kill()
        code = "timeout"
    out = b"" if stdout_tty else p.stdout.read()
    if stdout_tty:
        os.set_blocking(master, False)
        try:
            while chunk := os.read(master, 1 << 16):
                out += chunk
        except (BlockingIOError, OSError):
            pass
    os.close(slave)
    os.close(master)
    return code, out, p.stderr.read()


# With no filter: (stdin a terminal, stdout a terminal, arguments, what is typed or piped in, the variables
# set, and jq's output where it is pinned). Printed to a terminal, jq's output is in colour unless NO_COLOR
# is set and not empty.
DOC = b'{"a":[1,"x",null]}\n'
COLORED = (b'\x1b[1;39m{\x1b[0m\r\n  \x1b[1;34m"a"\x1b[0m\x1b[1;39m:\x1b[0m \x1b[1;39m[\x1b[0m\r\n'
           b'    \x1b[0;39m1\x1b[0m\x1b[1;39m,\x1b[0m\r\n    \x1b[0;32m"x"\x1b[0m\x1b[1;39m,\x1b[0m\r\n'
           b'    \x1b[0;90mnull\x1b[0m\r\n  \x1b[1;39m]\x1b[0m\r\n\x1b[1;39m}\x1b[0m\r\n')
TTY = [
    (True, True, [], b"", {}, None),
    (True, True, ["check"], b"", {}, None),
    (True, False, [], b"[1,2]\n\x04", {}, None),
    (False, True, ["-M"], b"[1,2]\n", {}, None),
    (True, False, ["-c"], b"{\"a\":1}\n\x04", {}, None),
    (False, True, [], DOC, {}, COLORED),
    (False, True, [], DOC, {"NO_COLOR": ""}, COLORED),
    (False, True, [], DOC, {"NO_COLOR": "1"}, b'{\r\n  "a": [\r\n    1,\r\n    "x",\r\n    null\r\n  ]\r\n}\r\n'),
    (False, True, [], DOC, {"JQ_COLORS": "4;31"}, COLORED.replace(b"0;90mnull", b"4;31mnull")),
]


# Filters and inputs the path scan or the record scan answers, each run as written and again as `FILTER | .` (or the
# filter given with it), which the interpreter answers: the two print the same bytes and exit alike.
FAST_ROUTE = [
    ([".a"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a.b[1]"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".zz"], '{"a":1}'),
    (["-c", ".a"], '{"a":1,"a":2}'),
    (["-c", ".a"], '{"a":1} {"a":[2]} {"b":3}'),
    (["-r", ".s"], '{"s":"x\\ty\\u00e9\\ud83d\\ude00"}'),
    (["-c", ".s"], '{"s":"x\\u007f\\u001f\\/"}'),
    (["-c", ".n"], '{"n":100000000000000000000000000001}'),
    (["-c", ".n"], '{"n":1E+2}'),
    (["-c", ".a.b"], '{"a":5}'),
    (["-c", ".a"], '[1]'),
    (["-c", '."a b"'], '{"a b":1}'),
    (["-c", ".a"], '{"a":1} tru'),
    (["--from", "ndjson", "-c", ".v"], '{"v":1}\n{"v":[2,3]}\n\n{"v":"s"}\n'),
    (["--from", "ndjson", "-c", "."], '{"v":1}\n{ "v" : [2, 3] }\n'),
    (["--from", "ndjson", "-c", ".v"], '{"v":1}\n{"v":\n'),
    # The record scan's compact encoding is the source's text, which jq's often is not.
    (["--from", "ndjson", "-c", "."], '"a\x7fb"\n{"x":1e2}\n"\\u0041\\/"\n[0.0000001,-0,1.0,"\\u00e9\\t"]\n'),
    (["--from", "ndjson", "-c", "."], '[1e-3]\n{"a":"0.0000001","b":2E+2}\n["1e5","4ef",0.5e1]\n' + '{"long":"%s","n":1e-3}\n' % ("x" * 40)),
    (["--from", "ndjson", "-r", "-c", "."], '"a"\n{"b":1}\n'),
    # A byte order mark past the input's first byte is the record's, which JSON refuses.
    (["--from", "ndjson", "-c", "."], '1\n﻿2\n'),
    (["--from", "ndjson", "-c", ".[]"], '[1]\n﻿[2]\n'),
]

# Past two batch workers' worth (2 MB), where an answer's array is laid out in pieces on the batch pool: plain
# records, and some jq respells (escapes, numbers, a repeated key, nesting past what the layout follows, DEL).
BIG = [json.dumps({"id": i, "tags": ["a", "b"], "s": "x" * 40}, separators=(",", ":")) for i in range(40000)]
ODD = ['{"a":"caf\\u00e9","b":"x\\/y"}', '{"n":1.0e5,"m":1E2,"o":0.10}', '{"k":1,"k":2}', "[" * 70 + "1" + "]" * 70, '"\x7f"', "[]"]
MIXED = [r if i % 997 else ODD[i // 997 % len(ODD)] for i, r in enumerate(BIG)]
FAST_ROUTE += [
    (["-c", "."], "[" + ",".join(MIXED) + "]"),
    (["."], '{"k": [' + ", ".join(MIXED) + "]}"),
    (["--tab", ".k"], '{"k": [' + ",\n".join(MIXED) + "]}"),
    (["--indent", "1", "."], "[" + ",".join([ODD[2]] + BIG + [ODD[0]]) + "]"),
    (["-j", "."], ' [ ' + " , ".join(BIG) + " ] "),
]

# `.`, and `.k` of `{"k": [...]}`, validate such a root's array in its pieces as they print them: a fault in one
# prints nothing, and jq's error follows. Another key, or one written with an escape, is no such path.
HALF = len(BIG) // 2
FAST_ROUTE += [
    (["."], "[" + ",".join(BIG[:HALF] + [""] + BIG[HALF:]) + "]"),
    (["-c", "."], '{"k": [' + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]}"),
    (["-c", "."], "[" + ",".join(BIG[:HALF] + ['"\\ud800"'] + BIG[HALF:]) + "]"),
    (["."], "[" + ",".join(BIG) + "] [1]"),
    (["-c", ".k"], '{"k": [' + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]}"),
    ([".k"], '{"k": [' + ",".join(BIG) + "]} 7"),
    (["-c", ".k"], '{"k": [' + ",".join(BIG) + "]} {"),
    (["-c", ".k"], '{"\\u006b": [' + ",".join(BIG) + "]}"),
    (["--from", "ndjson", "-c", "."], "\n".join(BIG[:HALF] + ["﻿[2]"] + BIG[HALF:])),
]

# A path with one `[]` over such a root's array, or the array of `{"k": [...]}`, is scanned in its pieces: an
# entry its steps miss is null. An entry of another kind, a fault, a text after or a limit leaves the text to
# the scan whole, and to jq's rules. Over records, each record is settled alone.
NULLS = BIG[:HALF] + ["{}", "null", '{"id":null,"tags":{}}'] + BIG[HALF:]
FAST_ROUTE += [
    (["-c", ".[].id"], "[" + ",".join(NULLS) + "]"),
    (["-r", ".k[].s"], '{"k": [' + ",".join(BIG) + "]}"),
    (["-c", ".[]"], "[" + ",".join(MIXED) + "]"),
    (["--tab", ".k[]"], '{"k": [' + ",\n".join(MIXED) + "]}"),
    (["-c", ".k[].tags[1]"], '{"k": [' + ",".join(NULLS) + "]}"),
    (["-c", ".[].id"], "[" + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]"),
    (["-c", ".[].id"], "[" + ",".join(BIG) + "] [1]"),
    (["-c", "first(.[].id)"], "[" + ",".join(["{}"] + BIG) + "]"),
    (["-c", ".tags[]"], "\n".join(BIG[:HALF] + ['{"tags":[]}', '{"tags":{"a":1,"a":2}}', "{}"] + BIG[HALF:])),
    # An object holder that repeats keys: each once, at its first place, with its last value.
    (["-c", ".a[].id"], '{"a":{' + ",".join('"k%d":{"id":%d,"s":"%s"}' % (i % 6000, i, "x" * 400) for i in range(8000)) + "}}"),
    (["-c", ".a[]"], '{"a":{' + ",".join('"k%d":{"id":%d,"s":"%s"}' % (i % 6000, i, "x" * 400) for i in range(8000)) + "}}"),
    # Entries that answer twice or not at all beside ones that answer once: the answers are not one per entry.
    (["-c", ".[].id"], "[" + ",".join(BIG[:HALF] + ['{"id":1,"id":2}', "5"] + BIG[HALF:]) + "]"),
    (["-c", ".k[].tags[0]"], '{"k": [' + ",".join(BIG[:HALF] + ['{"tags":[1],"x":1,"tags":[2,3]}', "[]", "null"] + BIG[HALF:]) + "]}"),
]

# Any other filter runs on such a root built in its pieces; a fault in one leaves it to the scan and a whole build.
FAST_ROUTE += [
    (["-c", ".[-1]"], "[" + ",".join(BIG) + "] [1]"),
    (["-c", ".k[0]"], '{"k": [' + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]}"),
    (["-c", ".[0] | keys"], "[" + ",".join(BIG) + "] 1"),
    # An error the filter raises tells the line jq's reader is on once it has read the root.
    (["-c", ".a"], "[" + ",".join(BIG) + "]"),
    # An output that is that root, its array, or a large array or object of a text built whole, is laid out
    # from its text in pieces.
    (["-c", "select(true), .k"], '{"k": [' + ",".join(MIXED) + "]}"),
    (["-c", ".k // 1, .j"], '{"j": 1, "k": [' + ",".join(MIXED) + "]}"),
]

# A filter that reads such a root's array only at constant indices, and otherwise only its length, type or
# keys, runs on it with only those entries built, after every piece is validated: against the root built whole
# (`. as $r | $r | FILTER`), with faults in entries it does not read, an error in one it does, and texts after.
WHOLE = ". as $r | $r | "
FAST_ROUTE += [(opts, stdin, WHOLE + opts[-1]) for opts, stdin in [
    (["-c", ".[0].id"], "[" + ",".join(BIG) + "]"),
    (["-c", ".k | length, type, (keys | length), .[-1].id, (.[39990:40010] | length), (.[5:9] | reverse | keys)"], '{"k": [' + ", ".join(BIG) + "]}"),
    (["-c", ".k | reverse | .[0].id, .[-2].id, (reverse | first.id), last.id"], '{"k":\n[' + ",\n".join(BIG) + "]\n}"),
    (["-c", "{a: .[7].id, b: (.[-8] | keys), c: \"\\(.[1].tags)\", d: (.[2].id + .[-3].id)}"], "[" + ",".join(MIXED) + "]"),
    (["-c", "if .[1].id == 0 then .[2].id else .[3].id end, .[-1].id, (.[0] | keys)"], "[" + ",".join(["5"] + BIG) + "]"),
    (["-c", "length"], "[" + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]"),
    (["-c", ".k[0]"], '{"k": [' + ",".join(BIG[:HALF] + ['"\\ud800"'] + BIG[HALF:]) + "]}"),
    (["-c", ".[-1]"], "[" + ",".join(BIG) + ",]"),
    # Read from one end only, the other end's entries are validated but not counted.
    (["-c", ".k[0].id, .k[3].id, (.k | first.id)"], '{"v": 1, "k": [' + ",".join(BIG) + "]}"),
    (["-c", ".k[-1].id, (.k | last.id), (.k | reverse | .[2].id)"], '{"k": [' + ",".join(BIG) + '], "v": 1}'),
    (["-c", ".[0].id"], "[" + ",".join(BIG + ['{"s": tru}']) + "]"),
    (["-c", ".k[-1].id"], '{"k": [' + ",".join(BIG[:HALF] + ['"\\ud800"'] + BIG[HALF:]) + "]}"),
    (["-c", ".[15], .[-15], .[2].n, .[-3].n"], "[" + ",".join('{"n":%d,"s":"%s"}' % (i, "x" * 300000) for i in range(12)) + "]"),
]]

# Texts one per line past 2 MB, without --from ndjson: once a text ends its line and the next line holds one, the
# lines are read as records on the batch pool, up to one that is anything else, and the stream goes on from
# there as jq reads it. Mid-stream: a parse error, texts that are no object, two texts on a line, a text over
# lines, a lone surrogate, a repeated key; and a first text over lines.
FAST_ROUTE += [
    (["-c", "."], "\n".join(MIXED)),
    (["."], "\n".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:])),
    (["-c", ".s"], "\n".join(BIG[:HALF] + ["5", '"str"', "[1]", "null"] + BIG[HALF:])),
    (["-r", ".s"], "\r\n".join(BIG[:HALF] + [BIG[0] + " " + BIG[1], '{"s":\n"over"}', ""] + BIG[HALF:])),
    (["-c", ".id"], "\n".join(BIG[:HALF] + ['{"id":"\\ud800x"}'] + BIG[HALF:])),
    (["-c", "select(.id > 39990)"], "\n".join(['{\n"id": 1}'] + MIXED)),
    # Records the batch leaves, far apart: the lines after each are read as records again.
    (["-c", ".id"], "\n".join(BIG[:10000] + ["5", '{"id":7,"id":8}', '{"id":\n9}'] + BIG[10000:30000] + ['"s"', "null"] + BIG[30000:])),
    (["-c", "select(.id > 39000)"], "\n".join(BIG[:10000] + ["5"] + BIG[10000:30000] + ['{"id":\n9}'] + BIG[30000:])),
]

# Runs held to a cap, as (arguments, stdin, MB, exit status, stdout or its count of lines). A reduce whose update
# rebuilds or regrows its whole state each step frees the state it replaces, as jq's reference counts do: each takes a
# few MB, where one that keeps every step's state takes GB. A faulty text's events before its fault are made as they
# are given, so the walk holds its path, not its events, and moves what it holds between its arenas no more often than
# it doubles. A sanitizer's shadow memory takes a few times the plain build's.
EVENTS, EVENTS_MB = 1000000, 300 if os.environ.get("STURY_SANITIZED") else 100
CAPPED = [(["-n", f], "", 100, 0, want + "\n") for f, want in [
    ('reduce range(50000) as $i (""; . + "abcdefghij" + " ") | length', "550000"),
    ('reduce range(50000) as $i ([]; . + [$i] + [$i]) | length', "100000"),
    ('reduce range(5000) as $i ({}; . + {($i | tostring): $i} + {a: 1}) | length', "5001"),
    ('reduce range(50000) as $i (""; "\\(.)abcdefghij ") | length', "550000"),
    ('last(foreach range(20000) as $i (""; . + "abcdefghij" + " "; length))', "220000"),
]] + [
    (["-c", "--stream", "."], "[" + "1," * EVENTS + "x]", EVENTS_MB, 5, EVENTS),
    (["-c", "--stream-errors", "."], "[" + "1," * EVENTS + "x]", EVENTS_MB, 0, EVENTS + 1),
    (["-c", "--stream-errors", "."], '{"' + "k" * 1200000 + '":[1' + " " * 300000 + " tru]}", EVENTS_MB, 0, 1),
]


def check_capped(stury, diff, argv, stdin, cap, code, want):
    try:
        p = run_capped([stury, *argv], stdin.encode(), TIMEOUT, cap_mb=cap)
        got = (p.returncode, p.stdout.count(b"\n") if isinstance(want, int) else p.stdout.decode(errors="replace"))
        why = None if got == (code, want) else f"exit {got[0]}, {str(got[1])[:40]!r} (want exit {code}, {str(want)[:40]!r})"
    except subprocess.TimeoutExpired:
        why = f"past {cap} MB or {TIMEOUT:g} s"
    return "memory", f"held to {cap} MB: stury {' '.join(argv)} <<< {stdin[:40]!r}", why


# Stdin that is a regular file is mapped from its current offset, a pipe is read as it comes, and an empty file is no
# input: each answers alike, each part a pipe is written in a window of its own, and under --diff as jq does on a
# text in one part. (filter, text, offset, parts)
STDIN = [(f, text, offset, None) for offset, text in [
    (0, b'{"a":[1,2,{"b":"\xc3\xa9"}],"id":7}\n'),
    (7, b'"x"\n{"a":[1,2,{"b":"\xc3\xa9"}],"id":7}\n'),
    (20001, b'"' + b"y" * 20000 + b'"\n[1,{"id":2}]\n[3]\n'),
    (0, b""),
] for f in (["-c", "."], [".id? // empty"], ["-c", ".[]?"])] + [(f, b"".join(parts), 0, parts) for f, parts in [
    (["--from", "ndjson", "-c", "."], [b"1\n", b"\xef\xbb\xbf2\n3\n"]),
    (["--from", "ndjson", "-c", ". | ."], [b"[1]\n", b"\xef\xbb\xbf[2]\n"]),
    (["--from", "ndjson", "-c", ".a"], [b'{"a":1}\n', b'\xef\xbb\xbf{"a":2}\n']),
]]


def check_stdin(stury, diff, filter, text, offset, parts):
    with tempfile.TemporaryFile() as f:
        f.write(text)
        f.flush()
        os.lseek(f.fileno(), offset, os.SEEK_SET)
        mapped = subprocess.run([stury] + filter, stdin=f, capture_output=True, timeout=TIMEOUT)
    r, w = os.pipe()
    p = subprocess.Popen([stury] + filter, stdin=r, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(r)
    try:
        for part in parts or [text[offset:]]:
            os.write(w, part)
            time.sleep(0.2)
    except BrokenPipeError:
        pass
    finally:
        os.close(w)
    out, err = p.communicate(timeout=TIMEOUT)
    got, piped = (mapped.returncode, mapped.stdout, mapped.stderr), (p.returncode, out, err)
    jq = run(["jq"] + filter, text[offset:].decode("utf-8", "surrogateescape")) if diff and not parts else piped
    why = None if got == piped and got[:2] == jq[:2] else f"file {got!r}, pipe {piped!r}, want {jq[:2]!r}"
    return "stdin", f"stdin from a file at {offset} and a pipe in {len(parts or [1])} parts: stury {' '.join(filter)} <<< {text[:60]!r}", why


# Output that cannot be written: stdout closed ends the run as jq ends it (exit 2, "writing output failed"); a
# nonblocking pipe that fills is written on as the reader drains it, short writes and EAGAIN included, in full
# and in order, over the paths that write the output in pieces (a record batch, an array's chunks) as over the
# plain one.
def check_stdout_closed(stury, diff, filter):
    # fd 1 is a read-only /dev/null rather than closed: a closed fd 1 is the next descriptor a start-up open
    # takes, so the output would land there, and a read-only one fails every write with the same EBADF.
    def run(argv):
        fd = os.open(os.devnull, os.O_RDONLY)
        try:
            return subprocess.run(argv, input=b'{"a":1}\n', stderr=subprocess.PIPE, stdout=fd, timeout=TIMEOUT)
        finally:
            os.close(fd)
    p = run([stury] + filter)
    want = b"jq: error: writing output failed: Bad file descriptor\n"
    got = (p.returncode, as_jq(p.stderr))
    if diff:
        want = run(["jq"] + filter).stderr
    why = None if got == (2, want) else f"exit {got[0]} err {got[1]!r}, want exit 2 err {want!r}"
    return "stdout closed", f"stdout closed: stury {' '.join(filter)}", why


# A reader that closes the pipe ends the run by SIGPIPE with nothing on stderr, as jq's ends, on every path that writes
# the output, the pool's included. Each filter runs several times, as the signal and the write's EPIPE race on macOS.
def check_stdout_pipe_closed(stury, diff, filter):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "in.json")
        with open(path, "w") as f:
            f.write("[" + ",".join('{"id":%d,"s":"%s"}' % (i, "x" * 20) for i in range(200000)) + "]\n")
        for _ in range(8):
            p = subprocess.Popen([stury] + filter + [path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            p.stdout.read(10)
            p.stdout.close()
            err = p.stderr.read()
            code = p.wait(timeout=TIMEOUT)
            if (code, err) != (-signal.SIGPIPE, b""):
                return "stdout pipe closed", f"stdout pipe closed: stury {' '.join(filter)}", f"exit {code} err {err!r}, want SIGPIPE and no message"
    return "stdout pipe closed", f"stdout pipe closed: stury {' '.join(filter)}", None


NONBLOCKING = [
    (["-c", ".n"], b"".join(b'{"n":%d}\n' % i for i in range(80000)), b"".join(b"%d\n" % i for i in range(80000))),
    (["-c", "."], b"[" + b",".join([b"123456789"] * 80000) + b"]", b"[" + b",".join([b"123456789"] * 80000) + b"]\n"),
    (["-c", ".[]"], b"[" + b",".join([b"123456789"] * 80000) + b"]", b"123456789\n" * 80000),
]


def check_stdout_nonblocking(stury, diff, filter, text, want):
    r, w = os.pipe()
    os.set_blocking(w, False)
    got = []
    # The reader starts late and reads slowly, so the pipe is full when the child writes.
    def drain():
        time.sleep(0.3)
        while chunk := os.read(r, 1 << 14):
            got.append(chunk)
            time.sleep(0.0005)

    t = threading.Thread(target=drain)
    t.start()
    try:
        p = subprocess.Popen([stury] + filter, stdin=subprocess.PIPE, stdout=w, stderr=subprocess.PIPE)
        os.close(w)
        _, err = p.communicate(text, timeout=TIMEOUT * 3)
    finally:
        t.join()
        os.close(r)
    out = b"".join(got)
    why = None if (p.returncode, out, err) == (0, want, b"") else f"exit {p.returncode}, {len(out)} of {len(want)} bytes, err {err!r}"
    return "stdout nonblocking", f"nonblocking stdout: stury {' '.join(filter)} ({len(text)} bytes in)", why


# Pretty-printing a deep nest holds a bounded part of it (the layout is written out as it goes, not whole): at
# 8000 levels the output is 128 MB, and a run that held it whole is past the cap.
def check_deep_pretty(stury, diff, depth):
    # ThreadSanitizer's shadow memory is resident over every byte the writer touches, so a cap that
    # catches a whole-output buffer in a plain build is already past under it.
    if SANITIZER == "thread":
        return "deep pretty (not run under ThreadSanitizer)", f"pretty {depth} levels", None
    cap = 64
    text = b"[" * depth + b"]" * depth
    try:
        p = run_capped([stury, "--max-depth", "100000", "."], text, TIMEOUT * 3, cap_mb=cap)
    except subprocess.TimeoutExpired:
        return "deep pretty", f"pretty {depth} levels", f"past {cap} MB or {TIMEOUT * 3:g} s"
    ok = p.returncode == 0 and len(p.stdout) == 2 * depth * depth + 1 and p.stdout.count(b"\n") == 2 * depth - 1
    return "deep pretty", f"pretty {depth} levels", None if ok else f"exit {p.returncode}, {len(p.stdout)} bytes"


DEEP_ENTRIES = ['{"id":%d,"s":"%s"}' % (i, "x" * 50000) for i in range(72)]
DEEP_AT = [6, 21, 40]


# A root object whose array sits beside other members, or in another object, is read and printed in pieces
# with the rest around it (`root_spine`): each text with the path P to its array, whose key repeats in some,
# outer and inner, before the array and after it; an array that is empty; strings that hold brackets, quotes
# and backslashes beside the spine. Against Python's reading (a repeated key's last value at its first place,
# as jq reads it) and, with --diff, against jq's.
BODY = ",".join(BIG)
SPINE_ROOTS = [
    ('{"version": 1, "k": [' + BODY + "]}", ["k"]),
    ('{"k": [' + BODY + '], "tail": "x"}', ["k"]),
    ('{"data": {"k": [' + BODY + "]}}", ["data", "k"]),
    ('{"a": [1, {"b": "]}"}], "data": {"x": "\\"]", "k":\n[' + BODY + '],\n"y": {"z": [3]}}, "t": "\\\\"}', ["data", "k"]),
    ('{"\\u0076": 1, "k": [' + BODY + '], "v\\"": {}, "v": 2}', ["k"]),
    ('{"k": [{"id": -1}], "v": 1, "k": [' + BODY + "]}", ["k"]),
    ('{"k": [' + BODY + '], "v": 1, "k": [{"id": -2}]}', ["k"]),
    ('{"data": {"k": [' + BODY + '], "k": [{"id": -3}]}, "e": 1}', ["data", "k"]),
    ('{"data": {"k": [' + BODY + ']}, "data": {"k": [{"id": -4}]}}', ["data", "k"]),
    ('{"k": [], "big": [' + BODY + '], "e": {"k": []}}', ["e", "k"]),
    ('{"k": [], "big": [' + BODY + '], "e": {"k": []}}', ["big"]),
]
SPINE_FILTERS = [".", "-c .", "-c P[0]", "-c P[-1] | {id}", "P | length", "-c P[].id", "-c P"]
# A root object that repeats its key is not one member: the last value is the object's, whatever the first is.
REPEATED = ['{"k": [' + BODY + '], "k": 0, "k": [1]}', '{"k": [' + BODY + '], "k": 0}', '{"k": [1], "k": [' + BODY + ']}',
            '{"k": [' + BODY + '], "k": [' + BODY + ']}']


def spine_outputs(text, path, filter):
    """`filter`'s outputs on `text`, the array at `path`, as jq prints them."""
    root = json.loads(text)
    a = functools.reduce(lambda v, k: v[k], path, root)
    outs = {
        ".": lambda: [root],
        ". | .": lambda: [root],
        "P[0]": lambda: [a[0] if a else None],
        "P[-1] | {id}": lambda: [{"id": a[-1]["id"] if a else None}],
        "P | length": lambda: [len(a)],
        "P[].id": lambda: [e["id"] for e in a],
        "P": lambda: [a],
    }[filter.removeprefix("-c ")]()
    dump = (lambda v: json.dumps(v, separators=(",", ":"))) if filter.startswith("-c ") else (lambda v: json.dumps(v, indent=2))
    return "".join(dump(v) + "\n" for v in outs).encode()


def spine_argv(filter, path):
    p = "".join("." + k for k in path)
    return filter.replace("P", p).split(" ", 1) if filter.startswith("-c ") else [filter.replace("P", p)]


def check_spine_root(stury, diff, text, path, filter, depth=None):
    argv = (["--max-depth", str(depth)] if depth else []) + spine_argv(filter, path)
    got = run([stury] + argv, text + "\n")
    want = (0, spine_outputs(text, path, filter), b"")
    if diff:  # a superset of the plain run: jq's answer is checked as well
        jq = run(["jq"] + jq_args(argv), text + "\n")
        if got == want and (got[:2] + (as_jq(got[2]),)) != jq:
            want = jq
    why = None if got == want else f"exit {got[0]}, {len(got[1])} bytes {got[2][:100]!r} (want exit {want[0]}, {len(want[1])} bytes)"
    return "fast route", f"spine root: stury {' '.join(argv)} <<< {text[:40]!r}...{text[-40:]!r}", why


# A fault beside the spine, before the array or after it, or an entry past --max-depth in a nested spine, is
# told as a whole read tells it, which `check` makes: the same message at the same line and column; with
# --diff, jq's message.
SPINE_FAULTS = [
    ('{"version": tru, "k": [' + BODY + "]}", ["k"]),
    ('{"k": [' + BODY + '], "tail": tru}', ["k"]),
    ('{"data": {"v": 1, "k": [' + BODY + '], "t": tru}, "e": 1}', ["data", "k"]),
]
SPINE_FAULT_FILTERS = [".", "-c .", "-c P[0]", "P | length", "-c P[].id", "-c P"]
# Under --max-depth 5 an entry `[[[[1]]]]` of `{"k": [...]}`, or `[[[1]]]` of `{"d": {"k": [...]}}`, sits at depth 6,
# wherever the cuts fall: each filter refuses it as `check` does. Under 6 the second is at the limit.
DEEP_SPINES = [(head + ",".join(DEEP_ENTRIES[:at] + [entry] + DEEP_ENTRIES[at + 1:]) + tail, path) for at in DEEP_AT
               for head, entry, tail, path in (('{"k":[', "[[[[1]]]]", "]}", ["k"]), ('{"d": {"k": [', "[[[1]]]", "]}}", ["d", "k"]))]


# jq's sentences that the filter's jq-spelled message uses where `check` uses the library's.
JQ_SENTENCES = {b"Exceeds depth limit for parsing": b"Exceeds the depth limit", b"Unfinished JSON term": b"Unfinished input",
                b"Invalid numeric literal": b"Invalid number"}


def told(err):
    """A parse error's message, line and column, as the filter and `check` tell it, less the source line, caret and flag hint that follow."""
    m = re.fullmatch(rb"stury: parse error: (?:(.*?)(?: at EOF)? at line (\d+), column (\d+)|<stdin>:(\d+):(\d+): (.*))\n(?:[^\n]*\n[ \t]*\^\n(?:\([^\n]*\)\n)?)?", err)
    return m and ((JQ_SENTENCES.get(m[1], m[1]), m[2], m[3]) if m[1] else (m[6], m[4], m[5]))


def uncareted(err):
    """`err` less the source line, caret and flag hint stury prints after a parse error, which jq does not."""
    return re.sub(rb"(parse error: [^\n]*\n)[^\n]*\n[ \t]*\^\n(?:\([^\n]*\)\n)?", rb"\1", err)


def check_spine_fault(stury, diff, text, path, filter, depth=None):
    limit = ["--max-depth", str(depth)] if depth else []
    argv = limit + spine_argv(filter, path)
    code, out, err = run([stury] + argv, text + "\n")
    whole = run([stury, "check"] + limit, text + "\n")
    why = None
    if (code, out, whole[0]) != (5, b"", 5) or told(err) is None or told(err) != told(whole[2]):
        why = f"exit {code} {err[:120]!r}; check: exit {whole[0]} {whole[2][:120]!r}"
    elif diff and not depth and (code, out, uncareted(as_jq(err))) != run(["jq"] + argv, text + "\n"):
        why = f"differs from jq: {as_jq(err)!r}"
    return "fast route", f"spine fault: stury {' '.join(argv)} <<< {text[:40]!r}...{text[-40:]!r}", why


def jq_args(args):
    """`args` as jq takes them: without the options only stury has (--max-depth, --from, --to) and their values."""
    out, k = [], 0
    while k < len(args):
        if args[k] in ("--max-depth", "--from", "--to"):
            k += 1
        else:
            out.append(args[k])
        k += 1
    return out

# The jq.test cases whose input or `fromjson` text stury reads by its own grammar, not
# jq's (docs/cli.md, "Differences from jq"): stury's exit status, its stdout, and how its stderr starts.
NON_FINITE = "Infinity and NaN have no JSON value"
NAN_ERRORS = "".join(f'"{m} at line 1, column {c} (while parsing \'{t}\')"\n' for t, m, c in [("NaN", NON_FINITE, 1), ("-NaN", NON_FINITE, 2)] + [(f"NaN{n}", NON_FINITE, 1) for n in ("1", "10", "100", "1000", "10000", "100000")])
DIFFERS = {
    ("jq.test", 1306): (5, "", "stury: parse error: Infinity and NaN have no JSON value at line 1, column 9\n"),  # Infinity, NaN
    ("jq.test", 2315): (5, "", "stury: error (at <stdin>:1): Invalid literal at line 1, column 2 (while parsing 'nan')\n"),
    ("jq.test", 2319): (5, "", "stury: parse error: Invalid literal at line 1, column 7\n"),  # nan
    ("jq.test", 2324): (0, NAN_ERRORS, ""),
    ("jq.test", 2407): (5, "", "stury: parse error: Invalid literal at line 1, column 14\n"),  # nan
    ("jq.test", 2498): (0, '"Invalid string literal; expected \\", but got \' at line 1, column 2 (while parsing \'{\'a\': 123}\')"\n', ""),  # the quote's column
    ("jq.test", 2558): (5, "", "stury: error (at <stdin>:1): Exceeds depth limit for parsing at line 1, column 1025 "),  # nesting past 1024
}


def run(argv, stdin):
    try:
        p = run_capped(argv, stdin.encode("utf-8", "surrogateescape"), TIMEOUT)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""


CONSTS = {"NaN": Decimal("NaN"), "Infinity": Decimal("Infinity"), "-Infinity": Decimal("-Infinity")}
DECODER = json.JSONDecoder(parse_float=Decimal, parse_int=Decimal, parse_constant=CONSTS.__getitem__)


def jq_value(v):
    """A decoded value whose equality is jq's: U+FFFD for a lone surrogate."""
    fix = lambda v: (re.sub("[\ud800-\udfff]", "�", v) if isinstance(v, str) else v)
    if isinstance(v, list):
        return [jq_value(x) for x in v]
    if isinstance(v, dict):
        return {fix(k): jq_value(x) for k, x in v.items()}
    return fix(v)


def load(text):
    """A JSON text as a value whose equality is jq's: decimal numbers, U+FFFD for a lone surrogate."""
    return jq_value(DECODER.decode(text))


NUMBER = re.compile(rb"-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")


def same_output(a, b):
    """Whether two outputs are the same bytes, or the same JSON values laid out alike and apart only in how numbers are
    spelled: stury prints a number as it was written, where jq prints decNumber's spelling."""
    if a == b:
        return True
    if NUMBER.sub(b"0", a) != NUMBER.sub(b"0", b):
        return False
    try:
        values = []
        for raw in (a, b):
            text, at, found = raw.decode("utf-8", "surrogateescape"), 0, []
            while at < len(text):
                if text[at] in " \t\r\n":
                    at += 1
                    continue
                value, at = DECODER.raw_decode(text, at)
                found.append(jq_value(value))
            values.append(found)
        return same(*values)
    except ValueError:
        return False


def same(a, b):
    if isinstance(a, Decimal) and isinstance(b, Decimal):
        return a == b or (a.is_nan() and b.is_nan())
    if type(a) is not type(b):
        return False
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return a == b


def judge(case, code, out, err):
    """Why the case fails, or None."""
    if code == "timeout":
        return "timed out"
    if case["fail"]:
        if code != 3:
            return f"compiled (exit {code}), want a compile error"
        lines = as_jq(err).decode("utf-8", "replace").split("\n")
        last = ([l for l in lines if l.startswith("jq: error")] or [""])[-1]
        if case["fail"] == "msg" and last != case["msg"]:
            return f"message {last!r}, want {case['msg']!r}"
        return None
    got = out.decode("utf-8", "surrogateescape").split("\n")
    if got and got[-1] == "":
        got.pop()
    for i, want in enumerate(case["want"]):
        if i >= len(got):
            return f"{len(got)} outputs, want {len(case['want'])}"
        try:
            if not same(load(got[i]), load(want)):
                return f"output {i + 1} is {got[i]}, want {want}"
        except ValueError:
            return f"output {i + 1} is {got[i]!r}, not JSON"
    if len(got) > len(case["want"]):
        return f"superfluous output {got[len(case['want'])]}"
    return None


def describe(case):
    return f"{case['file']}:{case['line']}: {case['prog']}"


def check_suite(stury, diff, case):
    """A jq.test or onig.test case: (its tally, what it is, why it fails or None)."""
    argv = [stury, "-L", MODULE_DIR, "-c", case["prog"]]
    stdin = (case.get("input") or "null") + "\n"
    code, out, err = run(argv, stdin)
    own = DIFFERS.get((case["file"], case["line"]))
    if own:
        ok = code == own[0] and out == own[1].encode() and err.startswith(own[2].encode())
        why = None if ok else f"stury: exit {code} out {out!r} err {err[:300]!r}, documented as {own}"
    else:
        why = judge(case, code, out, err)
    if why is None and diff and not own:
        jq = run(["jq"] + argv[1:], stdin)
        if (code, as_jq(err)) != (jq[0], jq[2]) or not same_output(out, jq[1]):
            why = f"differs from jq:\n     stury: exit {code} out {out!r} err {as_jq(err)!r}\n     jq:    exit {jq[0]} out {jq[1]!r} err {jq[2]!r}"
    return case["file"], describe(case) + f"\n     input: {stdin.strip()}", why


def check_fast_route(stury, diff, opts, stdin, *whole):
    fast = run([stury] + opts, stdin + "\n")
    slow = run([stury] + opts[:-1] + [whole[0] if whole else opts[-1] + " | ."], stdin + "\n")
    why = None
    if fast != slow:
        why = f"path scan: {fast}\n     interpreter: {slow}"
    elif diff:
        jq = run(["jq"] + jq_args(opts), stdin + "\n")
        # A parse error names the library's fault, at its byte, not jq's message (docs/cli.md, "Differences from jq").
        parse_errors = all(e.startswith(b"jq: parse error: ") for e in (as_jq(fast[2]), jq[2]))
        if fast[0] != jq[0] or not same_output(fast[1], jq[1]) or as_jq(fast[2]) != jq[2] and not parse_errors:
            why = f"differs from jq: {fast} vs {jq}"
    return "fast route", f"fast route: stury {' '.join(opts)} <<< {stdin[:200]!r}", why


@functools.cache
def jq_here():
    try:
        return subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip() == "jq-1.8.2"
    except FileNotFoundError:
        return False


def posix_only(case):
    """Whether a cli.tsv row's answer is POSIX's: a closed stdout (run through /bin/sh), a `$DIR` path asked or
    answered (Windows spells it with backslashes), HOME or get_search_list (module search paths, which Windows makes
    absolute), a directory opened as a file, local time (the rows name their zone as tzdata does), the program's `/`
    origin, or an argument or variable that is not valid UTF-8 (Windows has UTF-16 only)."""
    asked = "\0".join(case["args"] + list(case["env"]) + [v for v in case["env"].values() if v])
    said = [w for w in case["want"] if isinstance(w, str)]
    return (case["closed"] or "$DIR" in asked or any("$DIR" in w for w in said) or "HOME" in case["env"] or re.search("[\ud800-\udfff]|localtime|get_prog_origin|get_jq_origin|get_search_list", asked)
            or any("Is a directory" in w for w in said))


# The --explain lines that vary from run to run.
EXPLAIN_VARIES = re.compile(rb"(?m)^stury: explain: (?:time|used|threads): .*\n")


def check_cli(stury, diff, case):
    if not case["want"]:
        return "cli.tsv", f"cli.tsv:{case['line']}: stury {' '.join(case['args'])}", "no recorded answer: run jq_suite.py --record"
    stdin = case["stdin"] if len(case["stdin"]) < 200 else case["stdin"][:200] + "..."
    files = f" files {case['files']}" if case["files"] else ""
    area, what = f"cli.tsv {case['area']}", f"cli.tsv:{case['line']}: stury {' '.join(case['args'])} <<< {stdin!r}{files}"
    if case["slow"] and SANITIZER == "thread":
        return f"{area} (deep recursion, not run under ThreadSanitizer)", what, None
    # cli.tsv is recorded on macOS. A `libc` row's answer is the C library's (libm's last digits, the fields
    # strptime derives, timegm's range), so elsewhere it is checked against this platform's jq.
    on_platform_jq = case["area"] == "libc" and sys.platform != "darwin"
    if os.name == "nt" and posix_only(case):
        return f"{area} (POSIX only, not run)", what, None
    if on_platform_jq and os.name == "nt":  # jq's Windows build reads TZ and fills tm_yday wrong: no reference
        return f"{area} (no reference jq on Windows, not run)", what, None
    if on_platform_jq and not jq_here():
        return f"{area} (no jq 1.8.2 here, not run)", what, None
    code, out, err = run_cli(stury, case)
    if case["area"] == "explain":
        err = EXPLAIN_VARIES.sub(b"", err)
    enc = lambda w: [w[0]] + [None if s is None else s.encode("utf-8", "surrogateescape") for s in w[1:]]
    jq, own = enc(case["want"][:3]), case["want"][3:]
    if on_platform_jq:
        jq = list(run_cli("jq", case))
    got, want, who = ([code, out, err], enc(own), "stury") if own else ([code, out, as_jq(err)], jq, "jq")
    why = None if got == want else f"stury: exit {code} out {out!r} err {err!r}\n     {who + ':':6} exit {want[0]} out {want[1]!r} err {want[2]!r}"
    if why is None and diff and not on_platform_jq and jq[0] is not None:
        ref = list(run_cli("jq", case))
        if ref[0] == "timeout":
            area += f" (jq past {TIMEOUT:g} s, not run)"
        elif ref != jq:
            why = "the recorded answer is not jq's: run --record"
    return area, what, why


def check_tty(stury, diff, stdin_tty, stdout_tty, opts, feed, env, pinned):
    code, out, err = run_tty(stury, opts, stdin_tty, stdout_tty, feed, env)
    if stdin_tty and stdout_tty:
        usage = err.startswith(b"stury - command-line JSON and CSV processor") and err.endswith(b"For listing the command options, use stury --help.\n")
        why = None if (code, out) == (2, b"") and usage else f"exit {code} out {out!r} err {err!r}, want the usage and exit 2"
    else:
        want = run_tty("jq", opts, stdin_tty, stdout_tty, feed, env) if diff else None
        ok = code == 0 and out and out == (pinned or out) and (want is None or (code, out, err) == want)
        why = None if ok else f"exit {code} out {out!r} err {err!r}, jq {want or pinned}"
    return "terminal", f"terminal: {env} stury {' '.join(opts)} (stdin {'a terminal' if stdin_tty else 'piped'}, stdout {'a terminal' if stdout_tty else 'piped'})", why


def main():
    parser = argparse.ArgumentParser(description="jq 1.8.2's test suites and cli.tsv, run through a stury binary.")
    parser.add_argument("binary", nargs="?", default="build/stury")
    parser.add_argument("--diff", action="store_true", help="also run every case through jq 1.8.2 and require the same answer")
    parser.add_argument("--record", action="store_true", help="write jq 1.8.2's answers into cli.tsv rows that lack them or differ")
    options = parser.parse_args()
    diff = options.diff
    stury = os.path.abspath(options.binary)
    # Every case runs in one time zone, a zone with daylight saving, which cli.tsv's date rows were recorded in.
    os.environ["TZ"] = "America/New_York"
    # Colours are each case's own choice, not the caller's.
    os.environ.pop("JQ_COLORS", None)
    os.environ.pop("NO_COLOR", None)
    if os.name == "nt":  # the console's code page cannot print every failure's bytes
        sys.stdout.reconfigure(errors="backslashreplace")
    if diff or options.record:
        v = subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip()
        if v != "jq-1.8.2":
            sys.exit(f"--diff and --record need jq 1.8.2 on PATH, found {v or 'none'}")
    if options.record:
        record_cli(os.path.join(HERE, "cli.tsv"))
    cases = parse_suite(os.path.join(SUITE, "jq.test")) + parse_suite(os.path.join(SUITE, "onig.test"))
    jobs = [(check_suite, case) for case in cases]
    jobs += [(check_fast_route, *row) for row in FAST_ROUTE]
    jobs += [(check_spine_root, text, path, f) for text, path in SPINE_ROOTS for f in SPINE_FILTERS]
    jobs += [(check_spine_root, text, ["k"], f) for text in REPEATED for f in ("-c .", "-c . | .", "-c P")]
    jobs += [(check_spine_fault, text, path, f) for text, path in SPINE_FAULTS for f in SPINE_FAULT_FILTERS]
    jobs += [(check_spine_root, text, path, f, 6) for text, path in DEEP_SPINES[1::2] for f in ("-c .", "-c P", "P | length", "-c P[-1] | {id}")]
    jobs += [(check_spine_fault, text, path, f, 5) for text, path in DEEP_SPINES for f in ("-c .", "-c P", "P | length", "-c P[].id")]
    jobs += [(check_stdin, *row) for row in STDIN]
    if os.name == "nt":
        print("memory, stdout closed, stdout pipe closed, stdout nonblocking, deep pretty: skipped: they need POSIX descriptors or a memory reader", flush=True)
    else:
        jobs += [(check_capped, *row) for row in CAPPED]
        jobs += [(check_stdout_closed, f) for f in (["-c", "."], ["-c", ".a"], ["-c", "map(.)"], ["--unbuffered", "-c", "."])]
        jobs += [(check_stdout_nonblocking, *row) for row in NONBLOCKING]
        jobs += [(check_stdout_pipe_closed, f) for f in (["."], ["-c", ".[].id"], ["-r", ".[].s"], ["-n", "range(1e7)"])]
        jobs += [(check_deep_pretty, 8000)]
    jobs += [(check_cli, case) for case in parse_cli(os.path.join(HERE, "cli.tsv"))]
    if ptys_here():
        jobs += [(check_tty, *row) for row in TTY]
    else:
        print(f"terminal: {len(TTY)} case(s) skipped: this host has no pseudo-terminal devices", flush=True)
    with ThreadPoolExecutor(MAX_WORKERS) as pool:
        results = list(pool.map(lambda job: job[0](stury, diff, *job[1:]), jobs))

    tally, bad = {}, 0
    for area, what, why in results:
        t = tally.setdefault(area, [0, 0])
        t[0] += 1
        if why is None:
            t[1] += 1
            continue
        bad += 1
        why = why if len(why) < 600 else why[:600] + "..."
        print(f"FAIL {what}\n     {why}")
    for area, (total, ok) in tally.items():
        print(f"{area}: {ok} of {total} pass")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
