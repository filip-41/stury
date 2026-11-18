"""stury's own options and subcommands, and its CPU and memory guards, on what jq's command line does not pin
(cli.tsv pins that, in test_jq.py)."""

import functools
import os
import re
import subprocess
import tempfile
import time

import pytest

from capped import SANITIZED, peak

POOL = (os.cpu_count() or 1) >= 2
needs_pool = pytest.mark.skipif(not POOL, reason="a one-core host reads no pieces")


def lines(n, f):
    return "".join(f(i) + "\n" for i in range(n))


def text(out):
    return out.rstrip(b"\n").decode("utf-8", "replace")


# The files of each name, written when a test first asks for it. Each is a (file name, content) pair of the Files holding it.
FILES = {
    "digits300": ("digits300.json", lambda f: "[1" + "0" * 300 + "]\n"),
    "caps_ndjson": ("big.ndjson", lambda f: f.read(f.digits300) + "[1e5000]\n" + f.read(f.deep[1024])),
    "many": ("many.ndjson", lambda f: "".join(f.many_lines)),
    "many_bad": ("many_bad.ndjson", lambda f: "".join(f.many_lines[:300000]) + '{bad\n{"a":1}\n'),
    "many_step": ("many_step.ndjson", lambda f: "".join(f.many_lines[:300000]) + '5\n{"a":1}\n'),
    "bom": ("bom.ndjson", lambda f: "".join(f.many_lines[:200000]) + "\ufeff" + "".join(f.many_lines[200000:])),
    "wide": ("wide.json", lambda f: '{"u":[' + ",".join('{"a":%d}' % i for i in range(200000)) + "]}\n"),
    "table": ("table.json", lambda f: "[" + ",".join('{"n":%d}' % i for i in range(2000)) + "]\n"),
    "small": ("small.json", lambda f: '{"a":1}\n'),
    "seq_none": ("seq_none.ndjson", lambda f: lines(200000, lambda i: '{"a":%d}' % i)),
    "records_file": ("records.ndjson", lambda f: f.records),
    "levels_file": ("levels.ndjson", lambda f: f.levels),
    "nums": ("nums", lambda f: lines(200000, str)),
    "seq_errors": ("seq_errors.seq", lambda f: lines(200000, lambda i: '\x1e{"a":tru}')),
    "numbers": ("numbers.txt", lambda f: lines(300000, str)),
    "framed": ("framed.json", lambda f: '{"a":1,"logs":[' + ",".join('{"id":%d,"msg":"a line of text that makes each record long"}' % i for i in range(200000)) + '],"z":{}}\n'),
    "csv": ("big.csv", lambda f: "".join(f.csv_lines)),
}


class Files:
    """The long inputs, each written to the scratch directory when a test first asks for it."""

    def __init__(self, directory):
        self.dir = directory
        self.rows = 100000 if SANITIZED else 600000

    def write(self, name, content):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(content.encode("utf-8", "surrogateescape") if isinstance(content, str) else content)
        return path

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def __getattr__(self, key):
        name, content = FILES[key]
        path = self.write(name, content(self))
        setattr(self, key, path)
        return path

    @functools.cached_property
    def many_lines(self):
        return lines(400000, lambda i: '{"a":%d}' % i).splitlines(keepends=True)

    @functools.cached_property
    def records(self):
        return lines(1400000, lambda i: '{"id":%d,"msg":"a line of text that makes each record seventy bytes"}' % i)

    @functools.cached_property
    def levels(self):
        return lines(400000, lambda i: '{"id":%d,"level":"%s","msg":"a line of text that makes each record seventy bytes"}' % (i, "info" if i % 10 else "error"))

    @functools.cached_property
    def csv_lines(self):
        return ["id,msg,level\n"] + ["%d,a line of text that makes each record long,%s\n" % (i, "info" if i % 10 else "error") for i in range(self.rows)]

    @functools.cached_property
    def deep(self):
        return {n: self.write(f"deep{n}.json", "[" * n + "]" * n + "\n") for n in (1024, 1100, 10000, 10001)}

    @functools.cached_property
    def csv_sources(self):
        mid, rows = self.rows // 2, self.csv_lines
        broken = "x" + rows[mid - 1][rows[mid - 1].index(","):]
        return {"big": self.csv,
                "nul": self.write("nul.csv", "".join(rows) + ",x,y\n"),
                "bom": self.write("bom.csv", 'id,msg,level\n"\ufeffx",y,z\n' + "".join(rows[1:])),
                "mid": self.write("mid.csv", "".join(rows[:mid - 1] + [broken] + rows[mid:])),
                "bad": self.write("bad.csv", "".join(rows[:mid]) + "1,2\n")}


class Runner:
    def __init__(self, stury, directory):
        self.stury, self.dir, self.files = stury, directory, Files(directory)
        self.idle = 0 if SANITIZED else self.run("-n", "empty", cpu=10)[3]

    def run(self, *args, stdin=None, cpu=None, merged=False, **kw):
        """(exit status, stdout, stderr, peak resident MB) of `stury ARGS`. `stdin` is text written through a pipe."""
        if isinstance(stdin, str):
            stdin = stdin.encode("utf-8", "surrogateescape")
        with tempfile.TemporaryFile() as out:
            code, err, held = peak([self.stury, *args], subprocess.DEVNULL if stdin is None else stdin, out,
                                   subprocess.STDOUT if merged else subprocess.PIPE, cpu)
            out.seek(0)
            return code, out.read(), err, held >> 20

    def check(self, code, want, *args, **kw):
        """The exit status is `code` and stdout, less the newlines that end it, is `want`, either any when None."""
        got, out, err, _ = self.run(*args, **kw)
        assert (code is None or got == code) and (want is None or text(out) == want), \
            f"exit {got} (want {code})\n got: {text(out)[:300]}\nwant: {want}\n{text(err)[:300]}"

    def quick(self, code, want, *args):
        """`check` under a 2 s CPU limit, at a size where a quadratic reading would run far past it."""
        self.check(code, want, *args, cpu=None if SANITIZED else 2)

    def agree(self, f, path, *opts):
        """FILTER on PATH answers as `FILTER | .` does, which the cell scan and the record pool do not take."""
        got, want = self.run(*opts, f, path)[:3], self.run(*opts, f + " | .", path)[:3]
        assert got == want, f"exit {got[0]}, interpreter {want[0]}"
        return got[0]

    def explained(self, want, *args):
        """The run is the same as without --explain, and its ran, threads and fallback lines are WANT, counts of pieces and
        threads read as `some`."""
        code, out, err, _ = self.run("--explain", *args)
        lines = err.decode("utf-8", "surrogateescape").splitlines(keepends=True)
        rest = "".join(l for l in lines if not l.startswith("stury: explain: ")).encode("utf-8", "surrogateescape")
        seen = "".join(re.sub(r"threads: [1-9][0-9]* pieces? over [0-9]+ threads", "threads: some pieces over some threads", l)
                       for l in lines if re.match("stury: explain: (ran|threads|fallback):", l))
        assert (code, out, rest) == self.run(*args)[:3] and seen.rstrip("\n") == want, f"exit {code}\n got: {seen}\nwant: {want}"

    def capped(self, cap, want, *args, stdin=None, idle=None):
        """The answer is `want` and the peak is under CAP MB above the binary's own peak doing nothing."""
        code, out, _, mb = self.run(*args, stdin=stdin, cpu=None if SANITIZED else 10)
        mb = 0 if SANITIZED else mb - (self.idle if idle is None else idle)
        assert not code < 0 and text(out) == want and mb < cap, f"exit {code}, {mb} MB above idle\n got: {text(out)[:300]}\nwant: {want[:300]}"

    def piped(self, code, want, first, rest, *args, early=False):
        """FIRST is written to a pipe, then REST after 0.1 s, or when `early` once the answer to FIRST is out, within 2 s
        (10 s under a sanitizer). The answer with its stderr is `want`."""
        with tempfile.TemporaryFile() as out:
            p = subprocess.Popen([self.stury, *args], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT)
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
        assert (p.returncode, got) == (code, want) and in_time, \
            f"exit {p.returncode}, first answer {'in time' if in_time else 'late'}\n got: {got}\nwant: {want}"


@pytest.fixture(scope="module")
def s(stury, tmp_path_factory):
    return Runner(stury, str(tmp_path_factory.mktemp("smoke")))


# check accepts what `stury .` accepts, the library's grammar, with nesting to 1024 and no digit or exponent cap (the
# small cases are cli.tsv's, these files are too long for it). --from jsonc validates against the same caps.
@pytest.mark.parametrize("name, code", (("deep1024", 0), ("digits300", 0), ("deep1100", 5), ("deep10000", 5), ("deep10001", 5)))
def test_check_caps(s, name, code):
    path = s.files.digits300 if name == "digits300" else s.files.deep[int(name[4:])]
    s.check(code, "", "check", path)
    s.check(code, None if code == 0 else "", "-c", ".", path)
    if name != "deep10000":
        s.check(code, "", "check", "--from", "jsonc", path)


def test_check_ndjson_caps(s):
    s.check(0, "", "check", "--from", "ndjson", s.files.caps_ndjson)


def test_digits300_pipe(s):
    """One text of 300-digit numbers through a pipe, over more than one window, is read on past each window's end, as a file is."""
    s.check(0, "40001", "length", stdin="[" + ("1" * 300 + ",\n") * 40000 + "1]\n", merged=True)


@pytest.mark.parametrize("i", range(3))
def test_seq_pipe_windows(s, i):
    """Under --seq a record runs to the next separator, past a pipe's windows, as from a file."""
    seq = s.files.seq_none
    code, want = s.run("--seq", "-c", ".", seq, merged=True)[:2]
    s.check(code, text(want).replace(seq, "<stdin>"), "--seq", "-c", ".", stdin=s.files.read(seq), merged=True)


QUICK = [
    ("many_texts", "399999", lambda f: ["-c", "select(.a > 399998) | .a", f.many]),
    ("slice_tail", "100000", lambda f: ["-c", ".u[100000:] | length", f.wide]),
    ("index_each", "199999", lambda f: ["-c", "last(range(100000; 200000) as $i | .u[$i].a)", f.wide]),
    # A variable that every piece reads by position, which no thread may write.
    ("shared_index", "1999", lambda f: ["--slurpfile", "t", f.table, "-c", "$t[0][.a % 2000].n as $n | select(.a == 399999) | $n", f.many]),
]


@pytest.mark.parametrize("name, want, args", QUICK, ids=[q[0] for q in QUICK])
def test_quick(s, name, want, args):
    s.quick(0, want, *args(s.files))


def test_bom_record(s):
    """A byte order mark past the first line ends the run there, on the record pool too."""
    s.check(None, lines(200000, str).rstrip("\n"), "-c", ".a", s.files.bom)


SOME = "stury: explain: threads: some pieces over some threads"
ONE = "stury: explain: threads: one"
EXPLAIN = [
    ("records", "many", ["-c", ".a"], f"stury: explain: ran: 400000 inputs, 400000 read by path and 0 built\n{SOME}"),
    ("records_fault", "many_bad", ["-c", ".a"], f"stury: explain: ran: 300001 inputs, 300000 read by path and 1 built\n{SOME}\n"
     "stury: explain: fallback: input 300001 was built, as it does not parse, and the filter run reports the fault"),
    ("records_step", "many_step", ["-c", ".a"], f"stury: explain: ran: 300002 inputs, 300001 read by path and 1 built\n{SOME}\n"
     "stury: explain: fallback: input 300001 was built, as a step met a value it does not apply to (.a over a number), where jq's rules answer"),
    ("root_pieces", "wide", ["-c", ".u[].a"], f"stury: explain: ran: 1 input, 1 read by path and 0 built\n{SOME}"),
    ("interpreter", "wide", ["-c", ".u | length"], f"stury: explain: ran: 1 input, each built\n{SOME}"),
    ("csv_pieces", "csv", ["--from", "csv", "-r", ".msg"], f"stury: explain: ran: 1 file, each record read by its columns\n{SOME}"),
]


@needs_pool
@pytest.mark.parametrize("name, file, args, want", EXPLAIN, ids=[e[0] for e in EXPLAIN])
def test_explain_pieces(s, name, file, args, want):
    s.explained(want, *args, getattr(s.files, file))


@pytest.mark.parametrize("args, want", ((["-c", ".a"], f"stury: explain: ran: 1 input, 1 read by path and 0 built\n{ONE}"),
                                        (["-c", ".a | tostring"], f"stury: explain: ran: 1 input, each built\n{ONE}")), ids=["path", "interpreter"])
def test_explain_small_file(s, args, want):
    s.explained(want, *args, s.files.small)


THREADED = (("records", ("-c", ".a"), "many"), ("root_entries", ("-c", ".u[].a"), "wide"), ("interpreter", ("-c", ".u | length"), "wide"),
            ("check", ("check", "--from", "ndjson"), "many"), ("fmt", ("fmt", "--from", "ndjson", "-c"), "many"),
            ("infer", ("schema", "infer", "--from", "ndjson"), "many"))


@pytest.mark.parametrize("name, args, file", THREADED, ids=[t[0] for t in THREADED])
def test_threads_answer_alike(s, name, args, file):
    """--threads sets the pool's width and nothing else: a long input answers the same at every width."""
    path = getattr(s.files, file)
    want = s.run(*args, path)[:3]
    for n in ("1", "3"):
        got = s.run(args[0], "--threads", n, *args[1:], path)[:3] if args[0] in ("check", "fmt", "schema") else s.run("--threads", n, *args, path)[:3]
        assert got == want, f"--threads {n}: exit {got[0]} (want {want[0]})"


@needs_pool
@pytest.mark.parametrize("n", ("1", "3"))
def test_threads_explain(s, n):
    err = s.run("--threads", n, "--explain", "-c", ".a", s.files.many)[2].decode()
    assert re.search(rf"threads: [1-9][0-9]* pieces? over {n} threads", err), err


# Recursion jq runs in constant memory, a million levels deep, and a string or object built by repeated `+` or `*`, which
# grows in place: each under 30 MB. Then idioms that build, take apart or loop over something big, each under about four
# times jq's own peak at the same size (a floor of 9 MB): any of them going quadratic lands far past its cap.
CAPPED = [
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
    # A long reduce frees each update's garbage as jq's reference counts do, its state copied with what it shares shared once.
    ("reduce_scoped", 9, "999999", "reduce range(1000000) as $i ({}; .a = $i) | .a"),
    ("reduce_scoped_shared", 38, "2", "reduce range(100000) as $i (null; [., .]) | length"),
    ("reduce_scoped_string", 46, "200000", '("x" * 100000) as $s | reduce range(200000) as $i ([]; . + [$s]) | length'),
]


@pytest.mark.parametrize("name, cap, want, f", CAPPED, ids=[c[0] for c in CAPPED])
def test_memory_of_idiom(s, name, cap, want, f):
    s.capped(cap, want, "-n", f)


@pytest.mark.parametrize("f", ("max", "min", "max_by(.)", "bsearch([$x])", "index($x)", "indices($x)", ". - [[$x]]"))
def test_too_deep_is_refused(s, f):
    """Values nested past jq's limit are refused by every comparison, as jq refuses them."""
    s.check(5, "", "-n", f"reduce range(10002) as $_ ([]; [.]) as $x | [$x, [$x]] | {f}")


def test_version_config_help(s):
    """-V, the build configuration and the help, which lists stury's own options."""
    version, config, usage = (text(s.run(opt)[1]) for opt in ("-V", "--build-configuration", "--help"))
    assert re.fullmatch(r"stury-([0-9a-f]{7,}|dev|[0-9]+\.[0-9]+\.[0-9]+)", version), version
    assert re.search(r"(?m)^odin .* -target:", config), config
    for opt in ("-V", "--version", "-h", "--help", "--build-configuration"):
        s.check(0, None, opt)
    assert re.search(r"(?m)^      --from format", usage), "--help lists --from"
    assert re.search(r"docs/cli.md in stury.s source", usage), "--help points to docs/cli.md"
    assert text(s.run("-h")[1]).startswith("stury - command-line JSON, YAML, TOML, XML, HTML, CSV and CBOR processor [version ")
    code, _, err, _ = s.run("-f")
    assert code == 2 and text(err).splitlines()[-1:] == ["For listing the command options, use stury --help."], f"-f with no file: exit {code}"


IDS = "".join('{"id":%d}\n' % i for i in range(6000))
# A pipe is read as it comes: the answer to what came first is out before the rest arrives. A text cut where the pipe
# pauses reads as jq reads it whole, and a byte order mark stays behind when a text on the stream's first line is read on.
PIPED = [
    ("pipe_records", 0, "1\n2", '{"a":1}\n', '{"a":2}\n', ("-c", ".a"), True),
    ("pipe_interpreter", 0, "2\n3", '{"a":1}\n', '{"a":2}\n', ("-c", ".a + 1"), True),
    ("pipe_raw", 0, '"a"\n"b"', "a\n", "b\n", ("-R", "."), True),
    ("pipe_stream", 0, "[[0],1]\n[[0]]\n[[0],2]\n[[0]]", "[1]\n", "[2]\n", ("--stream", "-c", "."), True),
    ("pipe_input", 0, "1\n2", "1\n", "2\n3\n", ("-n", "-c", "input, input"), True),
    ("cut_number", 0, "123\n4", "12", "3 4\n", ("-c", "."), False),
    ("cut_string", 0, '"abc"', '"ab', 'c"\n', ("-c", "."), False),
    ("cut_fault", 5, '{"a":1}\nstury: parse error: Expected value before \',\' at line 3, column 3\n2,,}\n  ^', '{"a":1}\n{"b":\n', "2,,}\n", ("-c", "."), False),
    ("cut_fault_line", 5, "[true]\nstury: parse error: Invalid literal at line 1, column 10\ntrue [1, x\n         ^", "true [1,", " x\n", ("-c", "[.]"), False),
    ("cut_raw", 0, '"abc"\n"d"', "ab", "c\nd", ("-R", "."), False),
    ("cut_stream", 0, '[["a",0],1]\n[["a",1],2]\n[["a",1]]\n[["a"]]', '{"a":[1,', "2]}\n", ("--stream", "-c", "."), False),
    ("cut_bom", 0, "[1,2]", "﻿[1,\n", "2]\n", ("-c", "."), False),
    ("cut_bom_seq", 0, "\x1e1", "﻿\x1e1\n", "", ("--seq", "-c", "."), False),
    ("csv_cut_quoted", 0, '{"a":"x\\ny","b":"z"}', 'a,b\n"x\n', 'y",z\n', ("--from", "csv", "-c", "."), False),
    ("csv_cut_header", 0, '{"ab":"1"}', "a", "b\n1\n", ("--from", "csv", "-c", "."), False),
    ("csv_cut_fault", 5, '{"a":"1"}\nstury: parse error: <stdin>:3:2: Record has more fields than the first record\n2,3\n ^', "a\n1\n", "2,3\n", ("--from", "csv", "-c", "."), False),
    # A record is output once the reader holds the 64-byte block it ends in plus three more bytes, so the first chunk is longer than one block.
    ("pipe_csv", 0, "1\n" + "9\n" * 35 + "2", "a\n1\n" + "9\n" * 35, "2\n", ("--from", "csv", "-r", ".a"), True),
    ("pipe_csv_interp", 0, "1\n" + "9\n" * 35 + "2", "a\n1\n" + "9\n" * 35, "2\n", ("--from", "csv", "-r", ".a | ."), True),
    # --to csv on a JSON stream writes the header and first row as soon as the first input arrives, and each later row as its input arrives.
    ("pipe_to_csv", 0, "a,b\n1,2\n3,4", '{"a":1,"b":2}\n', '{"a":3,"b":4}\n', ("--to", "csv", "."), True),
    ("pipe_to_tsv", 0, "x\n1\n2", '{"x":1}\n', '{"x":2}\n', ("--to", "tsv", "."), True),
]


@pytest.mark.parametrize("name, code, want, first, rest, args, early", PIPED, ids=[p[0] for p in PIPED])
def test_pipe(s, name, code, want, first, rest, args, early):
    s.piped(code, want, first, rest, *args, early=early)


@pytest.mark.parametrize("name, stdin, message", (
    ("text", IDS + '{"id":\n,}\n', "stury: parse error: Expected value before ',' at line 6002, column 1\n,}\n^\n"),
    ("filter", IDS + "7", 'stury: error (at <stdin>:6000): Cannot index number with string ("id")\n'),
))
def test_pipe_fault_after_many_records(s, name, stdin, message):
    """The answers before a fault print, and the fault names its place."""
    got = s.run("-c", ".id", stdin=stdin)
    every_id = "".join("%d\n" % i for i in range(6000))
    assert (got[0], got[1].decode(), got[2].decode()) == (5, every_id, message), f"exit {got[0]}\n{got[2][:300]!r}"


def test_fmt_depth(s):
    """A pretty print of nested arrays indents each level, the innermost empty one on its own line."""
    depth = 1100
    want = "".join("  " * i + "[\n" for i in range(depth - 1)) + "  " * (depth - 1) + "[]\n" + "".join("  " * i + "]\n" for i in reversed(range(depth - 1)))
    s.check(0, want.rstrip("\n"), "fmt", "--max-depth", "2000", stdin="[" * depth + "]" * depth)


def last(s):
    return str(s.files.rows - 1)


def csv_pieces(s):
    want = text(s.run("--from", "csv", "-r", "(.msg, .id) | .", s.files.csv)[1])
    return want, ["--from", "csv", "-r", ".msg, .id", s.files.csv], {"idle": 0}


# A pipe is held a window at a time: 100 MB of records through one peak under 64 MB, and a regular file of them under 62 MB
# above idle. Each faulty --seq record is placed by line and column from the last. A text the path scan leaves to the
# interpreter (`.a` on a number) frees its document. A CSV file or pipe is held one window at a time, under -n as well,
# and a column-only filter is answered from the cells in pieces on the pool, with the interpreter's output bytes.
HELD = [
    ("pipe_records", 64, lambda s: (lines(1400000, str).rstrip("\n"), ["-c", ".id"], {"stdin": s.files.records, "idle": 0})),
    ("file_records", 62, lambda s: ("1399999", ["-c", "select(.id == 1399999) | .id", s.files.records_file], {})),
    ("inputs_small", 126, lambda s: ("200000", ["-n", "[inputs] | length", s.files.nums], {})),
    ("outputs_scoped", 18, lambda s: ('{"a":"1999999"}', ["-nc", 'range(2000000) | tostring | {a: .} | select(.a == "1999999")'], {})),
    ("seq_error_records", 23, lambda s: ("", ["--seq", "-c", ".", s.files.seq_errors], {})),
    ("scan_fallback", 78, lambda s: ("", [".a", s.files.numbers], {})),
    ("csv_file", 46, lambda s: (last(s), ["--from", "csv", "-r", f'select(.id == "{last(s)}") | .id', s.files.csv], {})),
    ("csv_pipe", 48, lambda s: (last(s), ["--from", "csv", "-r", f'select(.id == "{last(s)}") | .id'], {"stdin": "".join(s.files.csv_lines), "idle": 0})),
    ("csv_inputs", 46, lambda s: (str(s.files.rows), ["--from", "csv", "-n", "reduce inputs as $x (0; . + 1)", s.files.csv], {})),
    ("csv_slurp", 598, lambda s: (str(s.files.rows), ["--from", "csv", "-s", "length", s.files.csv], {})),
    ("csv_columns_pieces", 80, csv_pieces),
]


@pytest.mark.parametrize("name, cap, case", HELD, ids=[h[0] for h in HELD])
def test_memory_of_input(s, name, cap, case):
    want, args, kw = case(s)
    s.capped(cap, want, *args, **kw)


# Under -n the outputs printed and the inputs read past are let go as the run goes, as jq's reference counts let them go:
# 35 MB of records each through a peak under 48 MB.
INPUTS = [
    ("reduce_inputs", 46, "400000", ("-n", "reduce inputs as $x (0; . + 1)"), "file"),
    ("reduce_inputs_pipe", 46, "400000", ("-n", "reduce inputs as $x (0; . + 1)"), "pipe"),
    ("inputs_select_pipe", 46, "399990", ("-n", 'inputs | select(.level == "error" and .id > 399980) | .id'), "pipe"),
    # Without -n the first record's window is held while `inputs` reads on past it.
    ("reduce_inputs_held_pipe", 46, "399999", ("reduce inputs as $x (0; . + 1)",), "pipe"),
    ("foreach_inputs", 46, "400000", ("-n", "foreach inputs as $x (0; . + 1) | select(. == 400000)"), "file"),
    # `inputs` into what keeps none of them, or only its last output, or a reduce's state: each read past is let go.
    ("reduce_inputs_select", 46, "400", ("-n", "reduce (inputs | select(.id % 1000 == 0)) as $x (0; . + 1)"), "file"),
    # A file of several texts read by `input` in an output scope takes no room for its whole length.
    ("input_scoped", 9, "0\n1\n2", ("-n", "range(3) | input | .id"), "file"),
]


@pytest.mark.parametrize("name, cap, want, args, source", INPUTS, ids=[i[0] for i in INPUTS])
def test_inputs_memory(s, name, cap, want, args, source):
    if source == "file":
        s.capped(cap, want, *args, s.files.levels_file)
    else:
        s.capped(cap, want, *args, stdin=s.files.levels)


@pytest.mark.parametrize("o", (["-C"], ["-C", "-c"], ["-C", "--tab"]), ids=" ".join)
def test_framed_color(s, o):
    """A coloured print on the batch pool is framed as the single thread paints it, which -S is the reference for."""
    assert s.run(*o, ".", s.files.framed)[1] == s.run(*o, "-S", ".", s.files.framed)[1]


# --from csv and --from tsv. The small cases are in cli.tsv.
@pytest.mark.parametrize("fmt, round", (("csv", 'a,b\n"1","x,y"\n"he said ""hi""","l1\nl2"\n"","tab\there"\n'),
                                         ("tsv", "a\tb\n1\tx\\ty\n\\\\n\tl1\\nl2\\r\n\t\n")))
def test_csv_roundtrip(s, fmt, round):
    """Output of @csv and @tsv reads back as the original cells, including quotes, commas, newlines and escapes."""
    out = s.run("--from", fmt, "-r", f"[.a, .b] | @{fmt}", s.files.write("round", round))[1]
    assert out == round.split("\n", 1)[1].encode()


def test_csv_columns_fault(s):
    """On a fault in the last piece, every earlier record is printed, followed by the interpreter's message."""
    path = s.files.write("bad_tail.csv", "".join(s.files.csv_lines) + "1,2\n")
    assert s.agree(".msg", path, "--from", "csv", "-r") == 5


@pytest.mark.parametrize("src", ("big", "nul", "bom"))
@pytest.mark.parametrize("f", (".id", "[.msg, .id]", ".id, .msg"))
@pytest.mark.parametrize("to", ("csv", "tsv"))
def test_columns_to_dsv(s, to, f, src):
    """--to csv and --to tsv write those columns on the pool with the interpreter's output, a record the dialect cannot
    write (a lone null) ending the run after every earlier record."""
    s.agree(f, s.files.csv_sources[src], "--from", "csv", "--to", to)


def test_csv_columns_refused(s):
    code, out, _, _ = s.run("--from", "csv", "--to", "csv", ".id", s.files.csv_sources["nul"])
    assert code == 5 and text(out).rsplit("\n", 1)[-1] == str(s.files.rows - 1), f"exit {code}"
    # A first cell that starts with a byte order mark is quoted at the start of the output.
    assert s.run("--from", "csv", "--to", "csv", ".id", s.files.csv_sources["bom"])[1].startswith('"\ufeffx"\n'.encode())


@pytest.mark.parametrize("src", ("big", "nul", "bom", "mid", "bad"))
@pytest.mark.parametrize("f", ("{id}", "{id, m: .msg}", "select(.id | tonumber % 100000 == 0)", 'select(.level == "error" and .id != "10")', 'select(.id | test("77$"))'))
@pytest.mark.parametrize("to", ("csv", "json"))
def test_object_to_dsv(s, to, f, src):
    """An object of columns, `.` and `select(F)` over columns answer in pieces with the interpreter's output, through a
    record the dialect cannot write, one of the wrong width, and a filter error mid-file."""
    s.agree(f, s.files.csv_sources[src], "--from", "csv", "--to", to, *(["-c"] if to == "json" else []))


def test_json_all_columns(s):
    s.agree(".", s.files.csv, "--from", "csv", "--to", "json", "-c")


def test_fmt_in_place_spelling(s):
    """fmt --in-place changes only the layout, a second run changes nothing, and the file keeps its mode."""
    path = s.files.write("inplace.json", '{"b":1,"a":2,"b":3,"n":1e2,"s":"\\u00e9\\/"}')
    os.chmod(path, 0o640)
    s.run("fmt", "--in-place", path)
    assert s.files.read(path) == '{\n  "b": 1,\n  "a": 2,\n  "b": 3,\n  "n": 1e2,\n  "s": "\\u00e9\\/"\n}\n'
    s.check(0, "", "fmt", "--check", path)
    assert os.stat(path).st_mode & 0o777 == 0o640


def test_fmt_in_place_deep_untouched(s):
    """A value fmt does not write leaves the file as it was."""
    deep = s.files.write("inplace.deep.json", s.files.read(s.files.deep[1100]))
    s.check(5, "", "fmt", "--in-place", deep)
    assert s.files.read(deep) == s.files.read(s.files.deep[1100])


@pytest.mark.parametrize("name, held, args", (("whole", '{"n":"x"}', []), ("record", '{"n":1}\n{"n":"x"}\n', ["--from", "ndjson"])))
def test_fmt_schema_in_place_untouched(s, name, held, args):
    """fmt --schema leaves a file with a failure as it was, whole or a record of it, as it does a fault."""
    rule = s.files.write("inplace.schema.json", '{"type":"object","properties":{"n":{"type":"integer"}}}')
    failing = s.files.write(f"inplace.{name}.json", held)
    s.check(1, "", "fmt", "--schema", rule, *args, "--in-place", failing)
    assert s.files.read(failing) == held


def test_fmt_in_place_bare_name(s):
    """A bare name's temporary file goes beside it, not to TMPDIR, which may be another device."""
    s.files.write("bare.json", '{"a":1}')
    done = subprocess.run([s.stury, "fmt", "--in-place", "bare.json"], cwd=s.dir, env={**os.environ, "TMPDIR": os.path.join(s.dir, "absent")})
    assert done.returncode == 0


@pytest.mark.skipif(os.name != "posix", reason="modes are POSIX's")
@pytest.mark.parametrize("name, args", (("fmt", ["fmt", "--in-place"]), ("edit", ["edit", "--in-place", ".[0].a = 2"])))
def test_in_place_temporary_is_private(s, name, args):
    """The temporary file is the owner's alone from its creation until the run ends, under a umask that allows everything."""
    private = os.path.join(s.dir, f"private-{name}")
    os.mkdir(private)
    secret = os.path.join(private, "secret.json")
    big = "[" + ",".join(['{"a":1}'] * 1000000) + "]"
    modes = []
    for _ in range(8):
        with open(secret, "w") as f:
            f.write(big)
        os.chmod(secret, 0o600)
        proc = subprocess.Popen([s.stury, *args, secret], preexec_fn=lambda: os.umask(0))
        while proc.poll() is None:
            for t in os.listdir(private):
                if t != "secret.json":
                    try:
                        modes.append(os.stat(os.path.join(private, t)).st_mode & 0o777)
                    except FileNotFoundError:
                        pass
        if modes:
            break
    assert modes and all(m == 0o600 for m in modes), [oct(m) for m in modes]
    assert os.listdir(private) == ["secret.json"], "the temporary file is left behind"


def test_edit_in_place_bytes(s):
    """edit --in-place changes only the edited bytes, the file keeps its mode, and --check agrees."""
    path = s.files.write("edit.jsonc", '// lead\n{"b":1, "a":"\\u00e9\\/", "n":1e2}\n')
    os.chmod(path, 0o640)
    s.run("edit", "--from", "jsonc", "--in-place", ".b = 2", path)
    assert s.files.read(path) == '// lead\n{"b":2, "a":"\\u00e9\\/", "n":1e2}\n'
    assert os.stat(path).st_mode & 0o777 == 0o640
    s.check(0, "", "edit", "--from", "jsonc", "--check", ".b = 2", path)
    s.check(1, "", "edit", "--from", "jsonc", "--check", ".b = 3", path)


BODY = ",\n".join('{"a":1e2,"a":%d.50,"s":"\\u00e9\\/","n":[-0,1E5,0.10,{},[]]}' % i for i in range(40000))


@pytest.mark.parametrize("f, whole", (("array", "[" + BODY + "]"), ("object", '{"head": 1.0, "x": {"y": [] }, "rows": [' + BODY + '], "tail": {"k":1e2,"k":2}}')), ids=("array", "object"))
def test_fmt_pieces(s, f, whole):
    """fmt of a large array, or of an object holding one, written in pieces equals --from jsonc's whole, and a text cut short writes nothing."""
    pieces = s.files.write(f"pieces-{f}.json", whole + "\n")
    for o in ([], ["--tab"], ["--indent", "5"]):
        assert s.run("fmt", *o, pieces)[1] == s.run("fmt", "--from", "jsonc", *o, pieces)[1], " ".join(o)
    s.check(1, "", "fmt", "--check", pieces)
    s.check(5, "", "fmt", s.files.write(f"pieces_cut-{f}.json", whole[:-3] + "\n"))
    s.check(0, "", "fmt", "--check", s.files.write(f"pieces-{f}.got", s.run("fmt", pieces)[1]))


@pytest.mark.skipif(os.name != "posix", reason="/dev/stdin is POSIX's")
def test_pipe_dev_stdin(s):
    """A path that names an anonymous pipe (/dev/stdin, a process substitution's /dev/fd/N) reads as a file does."""
    s.check(0, "[1]", "-c", ".", "/dev/stdin", stdin="[1]\n")
    s.check(0, "[[2]]", "-nc", "--slurpfile", "x", "/dev/stdin", "$x", stdin="[2]\n")
    s.check(0, '"3\\n"', "-nc", "--rawfile", "r", "/dev/stdin", "$r", stdin="3\n")


@pytest.mark.skipif(os.name != "posix", reason="process substitution reads /dev/fd, which is POSIX's")
@pytest.mark.parametrize("script, want", (('"$0" -c . <(echo "[6]")', "[6]"), ('"$0" -n -f <(echo "7")', "7")), ids=("process_substitution", "program_file"))
def test_pipe_process_substitution(s, script, want):
    got = subprocess.run(["bash", "-c", script, s.stury], capture_output=True, text=True)
    assert got.stdout.strip() == want, got.stdout + got.stderr
