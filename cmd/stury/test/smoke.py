#!/usr/bin/env python3
"""The stury CLI end to end on what jq has not: its own options and subcommands, and the CPU and memory guards. jq's
command line is pinned byte for byte by cli.tsv (jq_suite.py). A failing case that smoke.floor does not list fails the
run, and `--write` lists this run's failures there.

    python3 cmd/stury/test/smoke.py [build/stury] [--write]

Under a sanitizer (STURY_SANITIZED set, as `make test-asan` sets it) the CPU and memory caps measure the sanitizer,
so only answers count.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from harness import peak

FLOOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "smoke.floor")
SANITIZED = bool(os.environ.get("STURY_SANITIZED"))
POOL = (os.cpu_count() or 1) >= 2
S = os.path.abspath(next((a for a in sys.argv[1:] if not a.startswith("--")), "build/stury"))
T = tempfile.mkdtemp()
failed = []


def over_budget(*_):
    """A hung case stalls the gate: the run, and any child still running, ends after a wall budget."""
    print(f"FAIL smoke: over its {BUDGET}s wall budget", flush=True)
    subprocess.run(["pkill", "-P", str(os.getpid())])
    os._exit(1)


BUDGET = 1800 if SANITIZED else 240
signal.signal(signal.SIGALRM, over_budget)
signal.alarm(BUDGET)


def fail(name, why):
    print(f"FAIL {name}: {why}")
    failed.append(name)


def file(name, text):
    path = os.path.join(T, name)
    with open(path, "wb") as f:
        f.write(text.encode("utf-8", "surrogateescape") if isinstance(text, str) else text)
    return path


def run(*args, stdin=None, cpu=None, merged=False):
    """(exit status, stdout, stderr, peak resident MB) of `stury ARGS`. `stdin` is text written through a pipe, or an
    open file; stderr joins stdout when `merged`."""
    if isinstance(stdin, str):
        stdin = stdin.encode("utf-8", "surrogateescape")
    with open(os.path.join(T, "out"), "w+b") as out:
        code, err, held = peak([S, *args], subprocess.DEVNULL if stdin is None else stdin, out,
                               subprocess.STDOUT if merged else subprocess.PIPE, cpu)
        out.seek(0)
        return code, out.read(), err, held >> 20


def text(out):
    return out.rstrip(b"\n").decode("utf-8", "replace")


def check(name, code, want, *args, **kw):
    """The exit status is `code` and stdout, less the newlines that end it, is `want`, either any when None."""
    got, out, err, _ = run(*args, **kw)
    if code is not None and got != code or want is not None and text(out) != want:
        fail(name, f"exit {got} (want {code})\n got: {text(out)[:300]}\nwant: {want}\n{text(err)[:300]}")


def quick(*row):
    """`check` under a 2 s CPU limit, at a size where the quadratic reading it guards against would run far past it."""
    check(*row, cpu=None if SANITIZED else 2)


def agree(name, f, path, *opts):
    """FILTER on PATH answers (stdout, stderr, exit status) as `FILTER | .` does, which the cell scan and the record pool
    do not take. The status is returned."""
    got, want = run(*opts, f, path)[:3], run(*opts, f + " | .", path)[:3]
    if got != want:
        fail(name, f"exit {got[0]}, interpreter {want[0]}")
    return got[0]


def explained(name, want, *args):
    """The run is the same as without --explain, and its ran, threads and fallback lines are WANT, the counts of pieces
    and threads read as `some`, since they follow the core count."""
    code, out, err, _ = run("--explain", *args)
    lines = err.decode("utf-8", "surrogateescape").splitlines(keepends=True)
    rest = "".join(l for l in lines if not l.startswith("stury: explain: ")).encode("utf-8", "surrogateescape")
    seen = "".join(re.sub(r"threads: [1-9][0-9]* pieces? over [0-9]+ threads", "threads: some pieces over some threads", l) for l in lines if re.match("stury: explain: (ran|threads|fallback):", l))
    if (code, out, rest) != run(*args)[:3] or seen.rstrip("\n") != want:
        fail(name, f"exit {code}\n got: {seen}\nwant: {want}")


IDLE = 0 if SANITIZED else run("-n", "empty", cpu=10)[3]


def capped(name, cap, want, *args, stdin=None, idle=IDLE):
    """The answer is `want`, and the peak is under CAP MB above the binary's own peak doing nothing (its code pages and
    runtime, which differ by platform). A 10 s CPU limit stops a runaway case, which fails it."""
    code, out, _, mb = run(*args, stdin=stdin, cpu=None if SANITIZED else 10)
    mb = 0 if SANITIZED else mb - idle
    if code < 0 or text(out) != want or mb >= cap:
        fail(name, f"exit {code}, {mb} MB above idle\n got: {text(out)[:300]}\nwant: {want[:300]}")


def piped(name, code, want, first, rest, *args, early=False):
    """FIRST is written to a pipe, then REST: after 0.1 s, or, when `early`, once the answer to FIRST is out, which
    must be within 2 s (10 s under a sanitizer, where TSan's start alone takes 0.4 s). The answer with its stderr is
    `want`."""
    with open(os.path.join(T, "piped"), "w+b") as out:
        p = subprocess.Popen([S, *args], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT)
        p.stdin.write(first.encode("utf-8", "surrogateescape"))
        p.stdin.flush()
        until = time.monotonic() + (10 if SANITIZED else 2)
        while early and time.monotonic() < until and not os.fstat(out.fileno()).st_size:
            time.sleep(0.05)
        early or time.sleep(0.1)
        in_time = not early or os.fstat(out.fileno()).st_size > 0
        p.stdin.write(rest.encode("utf-8", "surrogateescape"))
        p.stdin.close()
        p.wait()
        out.seek(0)
        got = text(out.read())
    if p.returncode != code or got != want or not in_time:
        fail(name, f"exit {p.returncode}, first answer {'in time' if in_time else 'late'}\n got: {got}\nwant: {want}")


def lines(n, f):
    return "".join(f(i) + "\n" for i in range(n))


# check accepts what `stury .` accepts, the library's grammar, with nesting to 1024 and no digit or exponent cap
# (the small cases are cli.tsv's; these files are too long for it). --from jsonc validates against the same caps.
caps = {f"deep{n}": file(f"deep{n}.json", "[" * n + "]" * n + "\n") for n in (1024, 1100, 10000, 10001)}
caps["digits300"] = file("digits300.json", "[1" + "0" * 300 + "]\n")
for f, code in (("deep1024", 0), ("digits300", 0), ("deep1100", 5), ("deep10000", 5), ("deep10001", 5)):
    check(f"check_{f}", code, "", "check", caps[f])
    check(f"dot_{f}", code, None if code == 0 else "", "-c", ".", caps[f])
    if f != "deep10000":
        check(f"check_jsonc_{f}", code, "", "check", "--from", "jsonc", caps[f])
big = file("big.ndjson", open(caps["digits300"]).read() + "[1e5000]\n" + open(caps["deep1024"]).read())
check("check_ndjson_caps", 0, "", "check", "--from", "ndjson", big)
# One text of 300-digit numbers through a pipe, over more than one window: it is read on past each window's end, as
# a file is.
check("digits300_pipe", 0, "40001", "length", stdin="[" + ("1" * 300 + ",\n") * 40000 + "1]\n", merged=True)
# Under --seq a record runs to the next separator, past a pipe's windows: NDJSON with none is one record, read as the
# file is, whatever windows the pipe came in.
seq = file("seq_none.ndjson", lines(200000, lambda i: '{"a":%d}' % i))
code, want = run("--seq", "-c", ".", seq, merged=True)[:2]
for i in range(3):
    check(f"seq_pipe_windows {i}", code, text(want).replace(seq, "<stdin>"), "--seq", "-c", ".", stdin=open(seq).read(), merged=True)

# Work that grows faster than the input.
many_lines = lines(400000, lambda i: '{"a":%d}' % i).splitlines(keepends=True)
many = file("many.ndjson", "".join(many_lines))
quick("many_texts", 0, "399999", "-c", "select(.a > 399998) | .a", many)
# A byte order mark past the first line ends the run there, on the record pool too.
bom = file("bom.ndjson", "".join(many_lines[:200000]) + "﻿" + "".join(many_lines[200000:]))
check("bom_record", None, lines(200000, str).rstrip("\n"), "-c", ".a", bom)
wide = file("wide.json", '{"u":[' + ",".join('{"a":%d}' % i for i in range(200000)) + "]}\n")
quick("slice_tail", 0, "100000", "-c", ".u[100000:] | length", wide)
quick("index_each", 0, "199999", "-c", "last(range(100000; 200000) as $i | .u[$i].a)", wide)
# A variable that every piece reads by position, which no thread may write.
table = file("table.json", "[" + ",".join('{"n":%d}' % i for i in range(2000)) + "]\n")
quick("shared_index", 0, "1999", "--slurpfile", "t", table, "-c", "$t[0][.a % 2000].n as $n | select(.a == 399999) | $n", many)
if POOL:  # a one-core host reads no pieces
    many_bad = file("many_bad.ndjson", "".join(many_lines[:300000]) + '{bad\n{"a":1}\n')
    many_step = file("many_step.ndjson", "".join(many_lines[:300000]) + '5\n{"a":1}\n')
    explained("explain_records", "stury: explain: ran: 400000 inputs, 400000 read by path and 0 built\nstury: explain: threads: some pieces over some threads", "-c", ".a", many)
    explained("explain_records_fault", "stury: explain: ran: 300001 inputs, 300000 read by path and 1 built\nstury: explain: threads: some pieces over some threads\n"
              "stury: explain: fallback: input 300001 was built, as it does not parse, and the filter run reports the fault", "-c", ".a", many_bad)
    explained("explain_records_step", "stury: explain: ran: 300002 inputs, 300001 read by path and 1 built\nstury: explain: threads: some pieces over some threads\n"
              "stury: explain: fallback: input 300001 was built, as a step met a value it does not apply to (.a over a number), where jq's rules answer", "-c", ".a", many_step)
    explained("explain_root_pieces", "stury: explain: ran: 1 input, 1 read by path and 0 built\nstury: explain: threads: some pieces over some threads", "-c", ".u[].a", wide)
    explained("explain_interpreter", "stury: explain: ran: 1 input, each built\nstury: explain: threads: some pieces over some threads", "-c", ".u | length", wide)
small = file("small.json", '{"a":1}\n')
explained("explain_small_file", "stury: explain: ran: 1 input, 1 read by path and 0 built\nstury: explain: threads: one", "-c", ".a", small)
explained("explain_small_interpreter", "stury: explain: ran: 1 input, each built\nstury: explain: threads: one", "-c", ".a | tostring", small)

# Recursion jq runs in constant memory, a million levels deep, and a string or object built by repeated `+` or `*`,
# which grows in place: each under 30 MB. Then idioms that build, take apart or loop over something big, each under
# about four times jq's own peak at the same size (a floor of 9 MB): any of them going quadratic lands far past its cap.
for name, cap, want, f in (
    ("bind_tail", 30, "1000000", "def f: . as $x | if $x < 1000000 then $x+1|f else $x end; 0|f"),
    ("def_tail", 30, "1000000", "def f: def g: .+1; if . < 1000000 then g|f else . end; 0|f"),
    ("add_strings", 30, "488890", "[range(100000) | tostring] | add | length"),
    ("reduce_string", 30, "100000", 'reduce range(100000) as $i (""; . + "x") | length'),
    ("reduce_array", 12, "8000", "reduce range(8000) as $i ([]; . + [$i]) | length"),
    ("reduce_object", 12, "3000", "reduce range(3000) as $i ({}; . + {($i|tostring): $i}) | length"),
    ("reduce_merge_nested", 13, "3000", "reduce range(3000) as $i ({}; . * {a: {($i|tostring): $i}}) | .a | length"),
    ("reduce_count", 12, "100", "reduce range(40000) as $i ({}; .[$i % 100 | tostring] += 1) | length"),
    ("foreach_string", 19, "800020000", '[foreach range(40000) as $i (""; . + "x"; utf8bytelength)] | add'),
    ("foreach_array", 15, "8000", "last(foreach range(8000) as $i ([]; . + [$i])) | length"),
    ("add_arrays", 13, "8000", "[range(8000) | [.]] | add | length"),
    ("add_objects", 18, "3000", "[range(3000) | {(tostring): .}] | add | length"),
    ("join", 30, "228889", '[range(40000) | tostring] | join(",") | length'),
    ("entries", 30, "3000", "[range(3000) | {(tostring): .}] | add | to_entries | from_entries | with_entries(.value += 1) | length"),
    ("group_by", 58, "100", "[range(20000) | {k: (. % 100), v: .}] | group_by(.k) | length"),
    ("paths", 84, "40000", "[range(20000) | {a: .}] | [paths] | length"),
    ("paths_deep", 28, "6000", "reduce range(6000) as $i (1; [.]) | reduce paths as $p (0; . + 1)"),
    ("setpath_reduce", 12, "3000", "reduce range(3000) as $i ({}; setpath([$i|tostring]; $i)) | length"),
    ("del_reduce", 13, "0", "reduce range(3000) as $i ([range(3000)]; del(.[0])) | length"),
    ("del_wide", 92, "0", "[range(20000) | {(tostring): .}] | add | del(.[]) | length"),
    ("limit", 9, "5", "[limit(5; range(1e12))] | length"),
    ("splits", 91, "20001", '[("a," * 20000) | splits(",")] | length'),
    ("gsub", 90, "40000", '"ab" * 20000 | gsub("a"; "x") | length'),
    ("tojson_roundtrip", 57, "20000", "[range(20000) | {a: .}] | tojson | fromjson | length"),
    ("range", 9, "2999999", "last(range(3000000))"),
    ("recurse_deep", 24, "10000", "reduce range(9999) as $_ ([]; [.]) | [recurse] | length"),
    ("walk_wide", 91, "20000", '[range(20000) | {a: [.]}] | walk(if type == "number" then . + 1 else . end) | length'),
    ("base64d", 15, "300000", '"abc" * 100000 | @base64 | @base64d | length'),
    ("test_regex", 42, "true", '"ab" * 100000 + "c" | test("(ab)*c$")'),
    ("regex_literal", 40, "true", '("a" * 3000000) as $p | "x" + $p | test($p)'),
    ("regex_deep", 30, '"Regex failure: parse depth limit over"', 'try ("a" | test("(" * 3000000 + "a" + ")" * 3000000)) catch .'),
    ("tostream", 27, "4000", "[range(4000) | {a: .}] | [tostream] | fromstream(.[]) | length"),
    # A long reduce frees each update's garbage as jq's reference counts do, its state copied with what it shares
    # shared once.
    ("reduce_scoped", 9, "999999", "reduce range(1000000) as $i ({}; .a = $i) | .a"),
    ("reduce_scoped_shared", 38, "2", "reduce range(100000) as $i (null; [., .]) | length"),
    ("reduce_scoped_string", 46, "200000", '("x" * 100000) as $s | reduce range(200000) as $i ([]; . + [$s]) | length'),
):
    capped(name, cap, want, "-n", f)
# Values nested past jq's limit are refused by every comparison, as jq refuses them.
for f in ("max", "min", "max_by(.)", "bsearch([$x])", "index($x)", "indices($x)", ". - [[$x]]"):
    check(f"too_deep {f}", 5, "", "-n", f"reduce range(10002) as $_ ([]; [.]) as $x | [$x, [$x]] | {f}")

# What stury tells of itself where jq tells of jq: -V as jq's `jq-VERSION`, the build configuration as the Odin command
# it was built with, and the help, which lists stury's own options too.
version, config, usage = (text(run(opt)[1]) for opt in ("-V", "--build-configuration", "--help"))
re.fullmatch(r"stury-([0-9a-f]{7,}|dev|[0-9]+\.[0-9]+\.[0-9]+)", version) or fail("-V", version)
re.search(r"(?m)^odin .* -target:", config) or fail("--build-configuration", config)
for opt in ("-V", "--version", "-h", "--help", "--build-configuration"):
    check(opt, 0, None, opt)
re.search(r"(?m)^      --from format", usage) or fail("--help lists --from", "")
re.search(r"docs/cli.md in stury.s source", usage) or fail("--help points to docs/cli.md", "")
text(run("-h")[1]).startswith("stury - command-line JSON and CSV processor [version ") or fail("-h", "")
code, _, err, _ = run("-f")
code == 2 and text(err).splitlines()[-1:] == ["For listing the command options, use stury --help."] or fail("-f with no file", f"exit {code}")

# A pipe is read as it comes: the answer to what came first is out before the rest arrives. A text cut where the pipe
# pauses reads as jq reads it whole, and a byte order mark stays behind when a text on the stream's first line is read on.
piped("pipe_records", 0, "1\n2", '{"a":1}\n', '{"a":2}\n', "-c", ".a", early=True)
piped("pipe_interpreter", 0, "2\n3", '{"a":1}\n', '{"a":2}\n', "-c", ".a + 1", early=True)
piped("pipe_raw", 0, '"a"\n"b"', "a\n", "b\n", "-R", ".", early=True)
piped("pipe_stream", 0, "[[0],1]\n[[0]]\n[[0],2]\n[[0]]", "[1]\n", "[2]\n", "--stream", "-c", ".", early=True)
piped("pipe_input", 0, "1\n2", "1\n", "2\n3\n", "-n", "-c", "input, input", early=True)
piped("cut_number", 0, "123\n4", "12", "3 4\n", "-c", ".")
piped("cut_string", 0, '"abc"', '"ab', 'c"\n', "-c", ".")
piped("cut_fault", 5, '{"a":1}\nstury: parse error: Expected value before \',\' at line 3, column 3\n2,,}\n  ^', '{"a":1}\n{"b":\n', "2,,}\n", "-c", ".")
piped("cut_fault_line", 5, "[true]\nstury: parse error: Invalid literal at line 1, column 10\ntrue [1, x\n         ^", "true [1,", " x\n", "-c", "[.]")
piped("cut_raw", 0, '"abc"\n"d"', "ab", "c\nd", "-R", ".")
piped("cut_stream", 0, '[["a",0],1]\n[["a",1],2]\n[["a",1]]\n[["a"]]', '{"a":[1,', "2]}\n", "--stream", "-c", ".")
piped("cut_bom", 0, "[1,2]", "﻿[1,\n", "2]\n", "-c", ".")
piped("cut_bom_seq", 0, "\x1e1", "﻿\x1e1\n", "", "--seq", "-c", ".")
# A pipe is held a window at a time: 100 MB of records through one peak under 64 MB, and a regular file of them under
# 62 MB above idle.
records = lines(1400000, lambda i: '{"id":%d,"msg":"a line of text that makes each record seventy bytes"}' % i)
big = file("big.ndjson", records)
capped("pipe_rss", 64, lines(1400000, str).rstrip("\n"), "-c", ".id", stdin=records, idle=0)
capped("file_rss", 62, "1399999", "-c", "select(.id == 1399999) | .id", big)
del records

# `[inputs]` under -n keeps a small text in about what it takes. Under -n the outputs printed and the inputs read past
# are let go as the run goes, as jq's reference counts let them go: 35 MB of records each through a peak under 48 MB.
capped("inputs_small", 126, "200000", "-n", "[inputs] | length", file("nums", lines(200000, str)))
records = lines(400000, lambda i: '{"id":%d,"level":"%s","msg":"a line of text that makes each record seventy bytes"}' % (i, "info" if i % 10 else "error"))
big = file("big.ndjson", records)
capped("reduce_inputs", 46, "400000", "-n", "reduce inputs as $x (0; . + 1)", big)
capped("reduce_inputs_pipe", 46, "400000", "-n", "reduce inputs as $x (0; . + 1)", stdin=records)
capped("inputs_select_pipe", 46, "399990", "-n", 'inputs | select(.level == "error" and .id > 399980) | .id', stdin=records)
# Without -n the first record's window is held while `inputs` reads on past it.
capped("reduce_inputs_held_pipe", 46, "399999", "reduce inputs as $x (0; . + 1)", stdin=records)
capped("foreach_inputs", 46, "400000", "-n", "foreach inputs as $x (0; . + 1) | select(. == 400000)", big)
# `inputs` into what keeps none of them, or only its last output, or a reduce's state: each read past is let go.
capped("reduce_inputs_select", 46, "400", "-n", "reduce (inputs | select(.id % 1000 == 0)) as $x (0; . + 1)", big)
capped("outputs_scoped", 18, '{"a":"1999999"}', "-nc", 'range(2000000) | tostring | {a: .} | select(.a == "1999999")')
# A file of several texts read by `input` in an output scope takes no room for its whole length.
capped("input_scoped", 9, "0\n1\n2", "-n", "range(3) | input | .id", big)
del records
# Each faulty --seq record is placed by line and column from the last, not from the start.
capped("seq_error_records", 23, "", "--seq", "-c", ".", file("seq_errors.seq", lines(200000, lambda i: '\x1e{"a":tru}')))
# A text the path scan leaves to the interpreter (`.a` on a number) frees its document.
capped("scan_fallback_free", 78, "", ".a", file("numbers.txt", lines(300000, str)))

# A coloured print of an array under an object runs on the batch pool, framed in the colours the single thread paints;
# -S (one thread, and these keys are sorted already) is the reference.
framed = file("framed.json", '{"a":1,"logs":[' + ",".join('{"id":%d,"msg":"a line of text that makes each record long"}' % i for i in range(200000)) + '],"z":{}}\n')
for o in (["-C"], ["-C", "-c"], ["-C", "--tab"]):
    run(*o, ".", framed)[1] == run(*o, "-S", ".", framed)[1] or fail(f"framed_color {' '.join(o)}", "the pool's print differs from one thread's")

# --from csv and --from tsv; the small cases are in cli.tsv. Output of @csv and @tsv reads back as the original cells,
# including quotes, commas, newlines and escapes. A stream or pipe split inside a record reads as one record.
for fmt, round in (("csv", 'a,b\n"1","x,y"\n"he said ""hi""","l1\nl2"\n"","tab\there"\n'), ("tsv", "a\tb\n1\tx\\ty\n\\\\n\tl1\\nl2\\r\n\t\n")):
    out = run("--from", fmt, "-r", f"[.a, .b] | @{fmt}", file("round", round))[1]
    out == round.split("\n", 1)[1].encode() or fail(f"{fmt}_roundtrip", out)
piped("csv_cut_quoted", 0, '{"a":"x\\ny","b":"z"}', 'a,b\n"x\n', 'y",z\n', "--from", "csv", "-c", ".")
piped("csv_cut_header", 0, '{"ab":"1"}', "a", "b\n1\n", "--from", "csv", "-c", ".")
piped("csv_cut_fault", 5, '{"a":"1"}\nstury: parse error: <stdin>:3:2: Record has more fields than the first record\n2,3\n ^', "a\n1\n", "2,3\n", "--from", "csv", "-c", ".")
# A record is output once the reader holds the 64-byte block it ends in plus three more bytes, so the first chunk is
# longer than one block.
for name, f in (("pipe_csv", ".a"), ("pipe_csv_interp", ".a | .")):
    piped(name, 0, "1\n" + "9\n" * 35 + "2", "a\n1\n" + "9\n" * 35, "2\n", "--from", "csv", "-r", f, early=True)
# A CSV file or pipe is held in memory one window at a time, under -n as well. A sanitized build reads fewer records,
# which still make many pieces on the pool.
rows = 100000 if SANITIZED else 600000
last = str(rows - 1)
csv_lines = ["id,msg,level\n"] + ["%d,a line of text that makes each record long,%s\n" % (i, "info" if i % 10 else "error") for i in range(rows)]
csv = file("big.csv", "".join(csv_lines))
capped("csv_file_rss", 46, last, "--from", "csv", "-r", f'select(.id == "{last}") | .id', csv)
capped("csv_pipe_rss", 48, last, "--from", "csv", "-r", f'select(.id == "{last}") | .id', stdin="".join(csv_lines), idle=0)
capped("csv_inputs_rss", 46, str(rows), "--from", "csv", "-n", "reduce inputs as $x (0; . + 1)", csv)
capped("csv_slurp", 598, str(rows), "--from", "csv", "-s", "length", csv)
# A column-only filter is answered from the cells in pieces on the pool, with the interpreter's output bytes. On a
# fault in the last piece, every earlier record is printed, followed by the interpreter's message.
capped("csv_columns_pieces", 80, text(run("--from", "csv", "-r", "(.msg, .id) | .", csv)[1]), "--from", "csv", "-r", ".msg, .id", csv, idle=0)
if POOL:
    explained("explain_csv_pieces", "stury: explain: ran: 1 file, each record read by its columns\nstury: explain: threads: some pieces over some threads", "--from", "csv", "-r", ".msg", csv)
code = agree("csv_columns_fault", ".msg", file("bad.csv", "".join(csv_lines) + "1,2\n"), "--from", "csv", "-r")
code == 5 or fail("csv_columns_fault", f"exit {code}")
# --to csv and --to tsv write those columns as records on the pool, with the interpreter's output. A record the
# dialect cannot write (a lone null) in the last piece ends the run after every earlier record. A first cell that
# starts with a byte order mark is quoted at the start of the output.
sources = {"big": csv, "nul": file("nul.csv", "".join(csv_lines) + ",x,y\n"),
           "bom": file("bom.csv", 'id,msg,level\n"﻿x",y,z\n' + "".join(csv_lines[1:]))}
for to in ("csv", "tsv"):
    for f in (".id", "[.msg, .id]", ".id, .msg"):
        for src, path in sources.items():
            agree(f"{to}_columns_{src} {f}", f, path, "--from", "csv", "--to", to)
code, out, _, _ = run("--from", "csv", "--to", "csv", ".id", sources["nul"])
code == 5 and text(out).rsplit("\n", 1)[-1] == last or fail("csv_columns_refused", f"exit {code}")
run("--from", "csv", "--to", "csv", ".id", sources["bom"])[1].startswith('"﻿x"\n'.encode()) or fail("csv_columns_bom", "")
# An object of columns, `.` and `select(F)` over columns are also answered in pieces, with the interpreter's output.
# The inputs include a record the dialect cannot write, a record of the wrong width, and a filter error in the middle
# of the file, after which the run continues with the next record.
mid = rows // 2
sources["mid"] = file("mid.csv", "".join(csv_lines[:mid - 1] + ["x" + csv_lines[mid - 1][csv_lines[mid - 1].index(","):]] + csv_lines[mid:]))
sources["bad"] = file("bad.csv", "".join(csv_lines[:mid]) + "1,2\n")
for f in ("{id}", "{id, m: .msg}", "select(.id | tonumber % 100000 == 0)", 'select(.level == "error" and .id != "10")', 'select(.id | test("77$"))'):
    for to in ("csv", "json"):
        for src, path in sources.items():
            agree(f"{to}_object_{src} {f}", f, path, "--from", "csv", "--to", to, *(["-c"] if to == "json" else []))
agree("json_all_columns", ".", csv, "--from", "csv", "--to", "json", "-c")
del csv_lines
# --to csv on a JSON stream writes the header and first row as soon as the first input arrives, and each later row as
# its input arrives.
piped("pipe_to_csv", 0, "a,b\n1,2\n3,4", '{"a":1,"b":2}\n', '{"a":3,"b":4}\n', "--to", "csv", ".", early=True)
piped("pipe_to_tsv", 0, "x\n1\n2", '{"x":1}\n', '{"x":2}\n', "--to", "tsv", ".", early=True)

# fmt --in-place changes only the layout: the spelling of numbers, strings and keys and a repeated key stay, a second
# run changes nothing, the file keeps its mode, and a value fmt does not write leaves the file as it was.
inplace = file("inplace.json", '{"b":1,"a":2,"b":3,"n":1e2,"s":"\\u00e9\\/"}')
os.chmod(inplace, 0o640)
run("fmt", "--in-place", inplace)
open(inplace).read() == '{\n  "b": 1,\n  "a": 2,\n  "b": 3,\n  "n": 1e2,\n  "s": "\\u00e9\\/"\n}\n' or fail("fmt_in_place_spelling", "")
check("fmt_in_place_again", 0, "", "fmt", "--check", inplace)
os.stat(inplace).st_mode & 0o777 == 0o640 or fail("fmt_in_place_mode", oct(os.stat(inplace).st_mode))
deep = file("inplace.deep.json", open(caps["deep1100"]).read())
check("fmt_in_place_deep", 5, "", "fmt", "--in-place", deep)
open(deep).read() == open(caps["deep1100"]).read() or fail("fmt_in_place_deep_untouched", "")
# fmt --schema leaves a file with a failure as it was, whole or a record of it, as it does a fault.
rule = file("inplace.schema.json", '{"type":"object","properties":{"n":{"type":"integer"}}}')
for name, held, args in (("whole", '{"n":"x"}', []), ("record", '{"n":1}\n{"n":"x"}\n', ["--from", "ndjson"])):
    failing = file(f"inplace.{name}.json", held)
    check(f"fmt_schema_in_place_{name}", 1, "", "fmt", "--schema", rule, *args, "--in-place", failing)
    open(failing).read() == held or fail(f"fmt_schema_in_place_{name}_untouched", open(failing).read())
# A bare name's temporary file goes beside it, not to TMPDIR, which may be another device.
file("bare.json", '{"a":1}')
subprocess.run([S, "fmt", "--in-place", "bare.json"], cwd=T, env={**os.environ, "TMPDIR": os.path.join(T, "absent")}).returncode == 0 or fail("fmt_in_place_bare_name", "")
# The temporary file is the owner's alone while it is written: it is watched from its creation until the run ends, under
# a umask that allows everything, while a large text is written and synced.
if os.name == "posix":
    private = os.path.join(T, "private")
    os.mkdir(private)
    secret = os.path.join(private, "secret.json")
    big = "[" + ",".join(['{"a":1}'] * 1000000) + "]"
    for name, args in (("fmt_in_place_temp_private", ["fmt", "--in-place"]), ("edit_in_place_temp_private", ["edit", "--in-place", ".[0].a = 2"])):
        modes = []
        for _ in range(8):
            with open(secret, "w") as f:
                f.write(big)
            os.chmod(secret, 0o600)
            proc = subprocess.Popen([S, *args, secret], preexec_fn=lambda: os.umask(0))
            while proc.poll() is None:
                for t in os.listdir(private):
                    if t != "secret.json":
                        try:
                            modes.append(os.stat(os.path.join(private, t)).st_mode & 0o777)
                        except FileNotFoundError:
                            pass
            if modes:
                break
        modes and all(m == 0o600 for m in modes) or fail(name, [oct(m) for m in modes])
        os.listdir(private) == ["secret.json"] or fail(name + "_removed", os.listdir(private))

# edit --in-place changes only the edited bytes: comments, spacing and the spelling of every other value stay, the
# file keeps its mode, and --check agrees.
edited = file("edit.jsonc", '// lead\n{"b":1, "a":"\\u00e9\\/", "n":1e2}\n')
os.chmod(edited, 0o640)
run("edit", "--from", "jsonc", "--in-place", ".b = 2", edited)
open(edited).read() == '// lead\n{"b":2, "a":"\\u00e9\\/", "n":1e2}\n' or fail("edit_in_place_bytes", "")
os.stat(edited).st_mode & 0o777 == 0o640 or fail("edit_in_place_mode", oct(os.stat(edited).st_mode))
check("edit_check_same", 0, "", "edit", "--from", "jsonc", "--check", ".b = 2", edited)
check("edit_check_change", 1, "", "edit", "--from", "jsonc", "--check", ".b = 3", edited)

# fmt of a large array, or of an object holding one, is written in pieces on the pool; --from jsonc reads the same text
# whole. Repeated keys and number and escape spellings stay either way, and a text cut short writes nothing.
body = ",\n".join('{"a":1e2,"a":%d.50,"s":"\\u00e9\\/","n":[-0,1E5,0.10,{},[]]}' % i for i in range(40000))
for f, whole in (("array", "[" + body + "]"), ("object", '{"head": 1.0, "x": {"y": [] }, "rows": [' + body + '], "tail": {"k":1e2,"k":2}}')):
    pieces = file("pieces.json", whole + "\n")
    for o in ([], ["--tab"], ["--indent", "5"]):
        run("fmt", *o, pieces)[1] == run("fmt", "--from", "jsonc", *o, pieces)[1] or fail(f"fmt_pieces_{f} {' '.join(o)}", "")
    check(f"fmt_pieces_{f}_check", 1, "", "fmt", "--check", pieces)
    check(f"fmt_pieces_{f}_cut", 5, "", "fmt", file("pieces_cut.json", whole[:-3] + "\n"))
check("fmt_pieces_again", 0, "", "fmt", "--check", file("pieces.got", run("fmt", pieces)[1]))

# A path that names an anonymous pipe (/dev/stdin, a process substitution's /dev/fd/N) reads as a file does.
check("pipe_dev_stdin", 0, "[1]", "-c", ".", "/dev/stdin", stdin="[1]\n")
check("pipe_dev_stdin_slurpfile", 0, "[[2]]", "-nc", "--slurpfile", "x", "/dev/stdin", "$x", stdin="[2]\n")
check("pipe_dev_stdin_rawfile", 0, '"3\\n"', "-nc", "--rawfile", "r", "/dev/stdin", "$r", stdin="3\n")
for name, script, want in (("pipe_process_substitution", '"$0" -c . <(echo "[6]")', "[6]"), ("pipe_program_file", '"$0" -n -f <(echo "7")', "7")):
    got = subprocess.run(["bash", "-c", script, S], capture_output=True, text=True)
    got.stdout.strip() == want or fail(name, got.stdout + got.stderr)

shutil.rmtree(T)
if "--write" in sys.argv:
    with open(FLOOR, "w") as f:
        f.writelines(name + "\n" for name in sorted(set(failed)))
known = set(open(FLOOR).read().splitlines())
new = sorted(set(failed) - known)
print(f"stury CLI smoke: {len(set(failed))} failing, {len(known)} listed in smoke.floor")
if new and "--write" not in sys.argv:
    sys.exit("failing and not in smoke.floor: " + ", ".join(new))
