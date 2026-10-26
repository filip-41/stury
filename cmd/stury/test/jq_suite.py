#!/usr/bin/env python3
"""jq 1.8.2's own test suites, and stury's command line cases, run through build/stury.

    python3 cmd/stury/test/jq_suite.py [build/stury] [--diff] [--record]

Each case of jq-1.8.2/jq.test and jq-1.8.2/onig.test (jq's tests/, verbatim at tag jq-1.8.2) runs as
`stury -L modules -c PROGRAM` with its input line on stdin, and passes as it does under `jq --run-tests`: each
output equals the expected value (numbers compared as decimals, so 1.0 equals 1), with nothing left
over; a `%%FAIL` program fails to compile (exit 3) with the expected first line of its last `jq: error`
message, as jq's test harness keeps the last (stury's `stury:` prefix read as jq's `jq:`).
FAST_ROUTE pins the path scan and the record scan to the interpreter: each runs as written and again as
`FILTER | .`, which the interpreter answers (or as the filter given with it), and the two must print the
same bytes and exit alike.
cli.tsv runs whole command lines (malformed input, no filter, --stream, --seq, several files) and
requires jq 1.8.2's exit status, stdout and stderr as recorded there, byte for byte; `--record` writes
them from the `jq` on PATH. A row where stury reads its input by its own grammar, not jq's (docs/cli.md's
"Differences from jq"), carries stury's own exit status, stdout and stderr after jq's, and stury must
answer those instead; a stury-only row (`check`) has null for jq's. DIFFERS is the same for jq.test
cases. The terminal cases run with no filter on a pseudo-terminal, where jq prints
its usage and exits 2 when both stdin and stdout are terminals, and reads `.` otherwise; a host with no
pseudo-terminal devices (Windows) skips them and says so. On Windows the cases that need POSIX are not run
either, and the report says so: the pipe and memory cases, and the cli.tsv rows `posix_only` picks.

--diff also runs every case through `jq` (1.8.2 on PATH) and requires stury's stdout, stderr and exit
status to equal jq's, byte for byte, with `stury:` read as `jq:`; for a documented difference, that jq
still answers what its row records.

The cases run on a thread pool; the report is in case order.
"""

import ctypes
import functools
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

try:
    import pty
except ImportError:  # Windows
    pty = None

HERE = os.path.dirname(os.path.abspath(__file__))
SUITE = os.path.join(HERE, "jq-1.8.2")
# Seconds a case may take; STURY_TEST_TIMEOUT raises it for a sanitized build (make test-asan).
TIMEOUT = float(os.environ.get("STURY_TEST_TIMEOUT", "10"))
sys.setrecursionlimit(100000)
# Megabytes a case may hold; macOS enforces no RLIMIT_AS, so a runaway case such as `[repeat(1)]` would
# otherwise take tens of GB before TIMEOUT stops it.
MEM_CAP_MB = int(os.environ.get("STURY_TEST_MEM_MB", "3000"))


def resident_mb(pid):
    """Process `pid`'s resident megabytes, read without starting a process (a `ps` per poll would stall the suite's
    stdin feeds); 0 when it is gone or the platform has no reader."""
    if sys.platform == "darwin":
        info = (ctypes.c_uint64 * 12)()  # struct proc_taskinfo; pti_resident_size is its second field
        n = _libproc.proc_pidinfo(pid, 4, 0, info, ctypes.sizeof(info))  # PROC_PIDTASKINFO
        return info[1] >> 20 if n == ctypes.sizeof(info) else 0
    if os.name == "nt":
        counters = (ctypes.c_size_t * 9)()  # PROCESS_MEMORY_COUNTERS on 64 bits: cb and the fault count share the first slot
        counters[0] = ctypes.sizeof(counters)
        h = _kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return 0
        try:
            return counters[2] >> 20 if _kernel32.K32GetProcessMemoryInfo(h, counters, ctypes.sizeof(counters)) else 0
        finally:
            _kernel32.CloseHandle(h)
    try:
        with open(f"/proc/{pid}/statm") as f:
            return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") >> 20
    except (OSError, IndexError, ValueError):
        return 0


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
_kernel32 = ctypes.WinDLL("kernel32") if os.name == "nt" else None
if _kernel32:
    _kernel32.OpenProcess.restype = ctypes.c_void_p
    _kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    _kernel32.K32GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    _kernel32.CloseHandle.argtypes = [ctypes.c_void_p]


# Cases running at once, and the resident megabytes all live children may hold before a new case waits to start:
# one worker per core with each child allowed MEM_CAP_MB would starve the cases of wall time.
MAX_WORKERS = min(8, os.cpu_count() or 1)
RSS_BUDGET_MB = int(os.environ.get("STURY_TEST_RSS_BUDGET_MB", "5000"))
_live = set()
_live_lock = threading.Lock()


def start_when_budget_allows(argv, **kw):
    """Popen of a child, started once the live children's resident sum is under RSS_BUDGET_MB (or none is live).
    The lock covers the sum and the set, not the spawn: under it, the workers started their children one at a
    time (a quarter of jq_diff's wall). A child a few ms old is not yet in another worker's sum, and holds nothing
    yet."""
    while True:
        with _live_lock:
            allowed = not _live or sum(resident_mb(q) for q in _live) <= RSS_BUDGET_MB
        if allowed:
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
            with _live_lock:
                _live.add(p.pid)
            return p
        time.sleep(0.05)


def run_capped(argv, input, timeout, cap_mb=MEM_CAP_MB, **kw):
    """subprocess.run with capture, killing the child past `timeout` or `cap_mb` resident; either raises
    subprocess.TimeoutExpired. One communicate() call: a retried one stops feeding stdin."""
    p = start_when_budget_allows(argv, **kw)
    done, over = threading.Event(), threading.Event()

    def watch():
        while not done.wait(0.05):
            if resident_mb(p.pid) > cap_mb:
                over.set()
                p.kill()
                return

    threading.Thread(target=watch, daemon=True).start()
    try:
        out, err = p.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise
    finally:
        done.set()
        with _live_lock:
            _live.discard(p.pid)
    if over.is_set():
        raise subprocess.TimeoutExpired(argv, timeout)
    return subprocess.CompletedProcess(argv, p.returncode, out, err)


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
    variables set."""
    cases = []
    for n, row in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if not row or row.startswith("#"):
            continue
        area, *cols = row.split("\t")
        args, stdin, files, *want = [json.loads(c) for c in cols]
        env = {}
        if isinstance(args, dict):
            env, args = args["env"], args["args"]
        cases.append({"line": n, "area": area, "args": args, "env": env, "stdin": stdin, "files": files, "want": want, "row": row})
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
            p = run_capped([binary] + args, enc(case["stdin"]), TIMEOUT, cwd=d, env=env)
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


# Filters and inputs the path scan or the record scan answers, each checked against the interpreter.
FAST_ROUTE = [
    ([".a"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a.b[1]"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a.b[-1]"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".a.b[5]"], '{"a":{"b":[1,"x"]}}'),
    (["-c", ".zz"], '{"a":1}'),
    (["-c", ".a"], '{"a":1,"a":2}'),
    (["-c", ".a"], '{"a":1} {"a":[2]} {"b":3}'),
    (["-r", ".s"], '{"s":"x\\ty\\u00e9\\ud83d\\ude00"}'),
    (["-c", ".s"], '{"s":"x\\u007f\\u001f\\/"}'),
    (["-c", ".n"], '{"n":1.000}'),
    (["-c", ".n"], '{"n":100000000000000000000000000001}'),
    (["-c", ".n"], '{"n":-0}'),
    (["-c", ".n"], '{"n":1E+2}'),
    (["-c", ".a.b"], '{"a":5}'),
    (["-c", ".[0]"], '{"a":5}'),
    (["-c", ".a"], '[1]'),
    (["-c", ".a"], 'null'),
    (["-c", '."a b"'], '{"a b":1}'),
    (["-c", '.["a"]'], '{"a":{"x":true}}'),
    (["-c", ".a"], '{"a":1} tru'),
    (["-c", ".a"], '{"a":1'),
    (["--from", "ndjson", "-c", ".v"], '{"v":1}\n{"v":[2,3]}\n\n{"v":"s"}\n'),
    (["--from", "ndjson", "-c", "."], '{"v":1}\n{ "v" : [2, 3] }\n'),
    (["--from", "ndjson", "-c", ".v"], '{"v":1}\n{"v":\n'),
    (["--from", "ndjson", "-c", ".v.w"], '{"v":1}\n'),
    (["--from", "ndjson", "-c", "."], '{"v":1}\n{"v":\n'),
    # The record scan's compact encoding is the source's text, which jq's often is not.
    (["--from", "ndjson", "-c", "."], '"a\x7fb"\n{"x":1e2}\n"\\u0041\\/"\n[0.0000001,-0,1.0,"\\u00e9\\t"]\n'),
    (["--from", "ndjson", "-c", "."], '[1e-3]\n{"a":"0.0000001","b":2E+2}\n["1e5","4ef",0.5e1]\n' + '{"long":"%s","n":1e-3}\n' % ("x" * 40)),
    (["--from", "ndjson", "-r", "-c", "."], '"a"\n{"b":1}\n'),
    (["--from", "ndjson", "-j", "-c", "."], '"a"\n{"b":1}\n'),
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
    (["-c", ".k"], '{"k": [' + ",".join(BIG[:HALF] + ['"\\ud800"'] + BIG[HALF:]) + "]}"),
    ([".k"], '{"k": [' + ",".join(BIG) + "]} 7"),
    (["-c", ".k"], '{"k": [' + ",".join(BIG) + "]} {"),
    (["-c", ".j"], '{"k": [' + ",".join(BIG) + "]}"),
    (["-c", ".k"], '{"\\u006b": [' + ",".join(BIG) + "]}"),
    (["-c", ".k"], '{"k": [' + ",".join(BIG) + "], }"),
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
    (["-c", ".[].id"], "[" + ",".join(MIXED) + "]"),
    (["-c", ".k[].tags[1]"], '{"k": [' + ",".join(NULLS) + "]}"),
    (["-c", ".[].id"], "[" + ",".join(BIG[:HALF] + ['{"s": tru}'] + BIG[HALF:]) + "]"),
    (["-c", ".[].id"], "[" + ",".join(BIG) + "] [1]"),
    (["-c", "first(.[].id)"], "[" + ",".join(["{}"] + BIG) + "]"),
    (["-c", ".j[]"], '{"k": [' + ",".join(BIG) + "]}"),
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
    (["-c", ".k.a"], '{"k":\n[' + ",\n".join(BIG) + "]\n}"),
    # An output that is that root, its array, or a large array or object of a text built whole, is laid out
    # from its text in pieces.
    (["-c", "select(true), .k"], '{"k": [' + ",".join(MIXED) + "]}"),
    ([".[]"], '{"k": [' + ",\n".join(MIXED) + "]}"),
    (["-c", ".k // 1, .j"], '{"j": 1, "k": [' + ",".join(MIXED) + "]}"),
    (["--tab", "-S", ".k // 1"], '{"j": 1, "k": [' + ",".join(BIG + [ODD[2]]) + "]}"),
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
    (["-c", ".k | length"], '{"k": [' + ",".join(BIG[:HALF] + [""] + BIG[HALF:]) + "]}"),
    (["-c", ".[-1]"], "[" + ",".join(BIG) + ",]"),
    (["-c", "length"], "[" + ",".join(BIG) + "] [1] {}"),
    (["-c", ".[0].id"], "[" + ",".join(BIG) + "] x"),
    # Read from one end only, the other end's entries are validated but not counted.
    (["-c", ".k[0].id, .k[3].id, (.k | first.id)"], '{"v": 1, "k": [' + ",".join(BIG) + "]}"),
    (["-c", ".k[-1].id, (.k | last.id), (.k | reverse | .[2].id)"], '{"k": [' + ",".join(BIG) + '], "v": 1}'),
    (["-c", ".[0].id"], "[" + ",".join(BIG + ['{"s": tru}']) + "]"),
    (["-c", ".[-1].id"], "[" + ",".join(['{"s": tru}'] + BIG) + "]"),
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
    (["-c", "select(.s == null)"], "\n".join(BIG[:HALF] + ['{"s":1,"s":null}', "7"] + BIG[HALF:])),
    (["-c", "select(.id == 3)"], "\n".join(BIG[:HALF] + ['{"id":3', "}"] + BIG[HALF:])),
    # Records the batch leaves, far apart: the lines after each are read as records again.
    (["-c", ".id"], "\n".join(BIG[:10000] + ["5", '{"id":7,"id":8}', '{"id":\n9}'] + BIG[10000:30000] + ['"s"', "null"] + BIG[30000:])),
    (["-c", "select(.id > 39000)"], "\n".join(BIG[:10000] + ["5"] + BIG[10000:30000] + ['{"id":\n9}'] + BIG[30000:])),
]

# A root object that repeats its key is not one member: the last value is the object's, whatever the first is.
BODY = ",".join(BIG)
REPEATED = [
    '{"k": [' + BODY + '], "k": 0, "k": [1]}',
    '{"k": [' + BODY + '], "k": 0}',
    '{"k": [1], "k": [' + BODY + ']}',
    '{"k": [' + BODY + '], "k": [' + BODY + ']}',
]


def check_repeated_root(stury, diff, filter, text):
    want = json.dumps(json.loads(text)["k"] if filter == ".k" else json.loads(text), separators=(",", ":")).encode() + b"\n"
    code, out, err = run([stury, "-c", filter], text + "\n")
    why = None if (code, out) == (0, want) else f"exit {code}, {len(out)} bytes (want {len(want)}) {err[:100]!r}"
    return "fast route", f"repeated root key: stury -c {filter!r} <<< {text[:40]!r}...{text[-30:]!r}", why


# A reduce whose update rebuilds or regrows its whole state each step frees the state it replaces, as jq's
# reference counts do: each takes a few MB, where one that keeps every step's state takes GB.
REDUCE_MEMORY = [
    ('reduce range(50000) as $i (""; . + "abcdefghij" + " ") | length', "550000"),
    ('reduce range(50000) as $i ([]; . + [$i] + [$i]) | length', "100000"),
    ('reduce range(5000) as $i ({}; . + {($i | tostring): $i} + {a: 1}) | length', "5001"),
    ('reduce range(50000) as $i (""; "\\(.)abcdefghij ") | length', "550000"),
    ('last(foreach range(20000) as $i (""; . + "abcdefghij" + " "; length))', "220000"),
]
REDUCE_MEMORY_MB = 100


def check_reduce_memory(stury, diff, filter, want):
    try:
        p = run_capped([stury, "-n", filter], b"", TIMEOUT, cap_mb=REDUCE_MEMORY_MB)
        why = None if (p.returncode, p.stdout) == (0, want.encode() + b"\n") else f"exit {p.returncode}, {p.stdout[:40]!r} (want {want})"
    except subprocess.TimeoutExpired:
        why = f"past {REDUCE_MEMORY_MB} MB or {TIMEOUT:g} s"
    return "memory", f"reduce frees its old state: stury -n {filter!r}", why


# Stdin that is a regular file is mapped from its current offset; a pipe is read; an empty file is no input.
# Each form must give what the pipe gives, and jq's output under --diff.
STDIN_FILES = [
    (0, b'{"a":[1,2,{"b":"\xc3\xa9"}],"id":7}\n'),
    (7, b'"x"\n{"a":[1,2,{"b":"\xc3\xa9"}],"id":7}\n'),
    (20001, b'"' + b"y" * 20000 + b'"\n[1,{"id":2}]\n[3]\n'),
    (0, b""),
]
STDIN_FILTERS = [["-c", "."], [".id? // empty"], ["-c", ".[]?"]]


def check_stdin_file(stury, diff, offset, text, filter):
    with tempfile.TemporaryFile() as f:
        f.write(text)
        f.flush()
        os.lseek(f.fileno(), offset, os.SEEK_SET)
        mapped = subprocess.run([stury] + filter, stdin=f, capture_output=True, timeout=TIMEOUT)
    rest = text[offset:].decode("utf-8", "surrogateescape")
    piped = run([stury] + filter, rest)
    want = run(["jq"] + filter, rest) if diff else piped
    got = (mapped.returncode, mapped.stdout)
    why = None if got == piped[:2] == want[:2] else f"file stdin {got!r}, pipe {piped[:2]!r}, want {want[:2]!r}"
    return "stdin file", f"stdin from a file at offset {offset}: stury {' '.join(filter)} ({len(text)} bytes)", why


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
    cap = 64
    text = b"[" * depth + b"]" * depth
    try:
        p = run_capped([stury, "--max-depth", "100000", "."], text, TIMEOUT * 3, cap_mb=cap)
    except subprocess.TimeoutExpired:
        return "deep pretty", f"pretty {depth} levels", f"past {cap} MB or {TIMEOUT * 3:g} s"
    ok = p.returncode == 0 and len(p.stdout) == 2 * depth * depth + 1 and p.stdout.count(b"\n") == 2 * depth - 1
    return "deep pretty", f"pretty {depth} levels", None if ok else f"exit {p.returncode}, {len(p.stdout)} bytes"


# Under --max-depth 5 an entry `[[[[1]]]]` of `{"k": [...]}` sits at depth 6, wherever the cuts fall: `.`,
# `.k`, `.k | length` and `check` refuse it alike, at the same column. jq has no such option, so no --diff row.
DEEP_ENTRIES = ['{"id":%d,"s":"%s"}' % (i, "x" * 50000) for i in range(72)]
DEEP_AT = [6, 21, 40]


def check_depth_refused(stury, diff, at):
    entries = DEEP_ENTRIES[:at] + ["[[[[1]]]]"] + DEEP_ENTRIES[at + 1:]
    text = '{"k":[' + ",".join(entries) + "]}\n"
    seen = set()
    for argv in (["--max-depth", "5", "-c", "."], ["--max-depth", "5", "-c", ".k"], ["--max-depth", "5", "-c", ".k | length"], ["check", "--max-depth", "5"]):
        code, _, err = run([stury] + argv, text)
        found = re.search(rb"column (\d+)|:1:(\d+):", err)
        seen.add((code, found.group(1) or found.group(2) if found else None))
    why = None if len(seen) == 1 and seen != {(5, None)} else f"(exit, column) differ or are missing: {sorted(seen, key=str)}"
    return "fast route", f"depth: entry {at} too deep under --max-depth 5", why


# A root object whose array sits beside other members, or in another object, is read and printed in pieces
# with the rest around it (`root_spine`): each text with the path P to its array, whose key repeats in some,
# outer and inner, before the array and after it; an array that is empty; strings that hold brackets, quotes
# and backslashes beside the spine. Against Python's reading (a repeated key's last value at its first place,
# as jq reads it) and, with --diff, against jq's.
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


def spine_outputs(text, path, filter):
    """`filter`'s outputs on `text`, the array at `path`, as jq prints them."""
    root = json.loads(text)
    a = functools.reduce(lambda v, k: v[k], path, root)
    outs = {
        ".": lambda: [root],
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
# Under --max-depth 6 an entry `[[[1]]]` of `{"d": {"k": [...]}}` sits at depth 6, the limit; under 5 past it.
DEEP_SPINES = [('{"d": {"k": [' + ",".join(DEEP_ENTRIES[:at] + ["[[[1]]]"] + DEEP_ENTRIES[at + 1:]) + "]}}", at) for at in DEEP_AT]


def told(err):
    """A parse error's message, line and column, as the filter and `check` tell it, less the source line, caret and flag hint that may follow."""
    m = re.fullmatch(rb"stury: (?:parse error: (.*) at line (\d+), column (\d+)|error: <stdin>:(\d+):(\d+): (.*))\n(?:[^\n]*\n[ \t]*\^\n\([^\n]*\)\n)?", err)
    return m and ((m[1], m[2], m[3]) if m[1] else (m[6], m[4], m[5]))


def check_spine_fault(stury, diff, text, path, filter, depth=None):
    limit = ["--max-depth", str(depth)] if depth else []
    argv = limit + spine_argv(filter, path)
    code, out, err = run([stury] + argv, text + "\n")
    whole = run([stury, "check"] + limit, text + "\n")
    why = None
    if (code, out, whole[0]) != (5, b"", 5) or told(err) is None or told(err) != told(whole[2]):
        why = f"exit {code} {err[:120]!r}; check: exit {whole[0]} {whole[2][:120]!r}"
    elif diff and not depth and (code, out, as_jq(err)) != run(["jq"] + argv, text + "\n"):
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
NAN_ERRORS = "".join(f'"{m} at line 1, column {c} (while parsing \'{t}\')"\n' for t, m, c in [("NaN", "Unexpected character", 1), ("-NaN", "Invalid numeric literal", 2)] + [(f"NaN{n}", "Unexpected character", 1) for n in ("1", "10", "100", "1000", "10000", "100000")])
DIFFERS = {
    ("jq.test", 1306): (5, "", "stury: parse error: Unexpected character at line 1, column 9\n"),  # Infinity, NaN
    ("jq.test", 2315): (5, "", "stury: error (at <stdin>:1): Invalid literal at line 1, column 2 (while parsing 'nan')\n"),
    ("jq.test", 2319): (5, "", "stury: parse error: Invalid literal at line 1, column 7\n"),  # nan
    ("jq.test", 2324): (0, NAN_ERRORS, ""),
    ("jq.test", 2407): (5, "", "stury: parse error: Invalid literal at line 1, column 14\n"),  # nan
    ("jq.test", 2498): (0, '"Unexpected character at line 1, column 2 (while parsing \'{\'a\': 123}\')"\n', ""),  # the fault's name
    ("jq.test", 2558): (5, "", "stury: error (at <stdin>:1): Exceeds depth limit for parsing at line 1, column 1025 "),  # nesting past 1024
}


def run(argv, stdin):
    try:
        p = run_capped(argv, stdin.encode("utf-8", "surrogateescape"), TIMEOUT)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""


def as_jq(stderr):
    """stury's messages with jq's program name."""
    return re.sub(rb"(?m)^stury: ", b"jq: ", stderr).replace(b"Use stury --help", b"Use jq --help")


def load(text):
    """A JSON text as a value whose equality is jq's: decimal numbers, U+FFFD for a lone surrogate."""
    fix = lambda v: (re.sub("[\ud800-\udfff]", "�", v) if isinstance(v, str) else v)

    def walk(v):
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, dict):
            return {fix(k): walk(x) for k, x in v.items()}
        return fix(v)

    consts = {"NaN": Decimal("NaN"), "Infinity": Decimal("Infinity"), "-Infinity": Decimal("-Infinity")}
    return walk(json.loads(text, parse_float=Decimal, parse_int=Decimal, parse_constant=consts.__getitem__))


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
        if (code, out, as_jq(err)) != jq:
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
        if (fast[0], fast[1]) != jq[:2] or as_jq(fast[2]) != jq[2] and not parse_errors:
            why = f"differs from jq: {fast} vs {jq}"
    return "fast route", f"fast route: stury {' '.join(opts)} <<< {stdin[:200]!r}", why


@functools.cache
def jq_here():
    try:
        return subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip() == "jq-1.8.2"
    except FileNotFoundError:
        return False


def posix_only(case):
    """Whether a cli.tsv row's answer is POSIX's: a `$DIR` path, HOME or get_search_list (module search paths, which Windows makes absolute), a directory opened
    as a file, local time (the rows name their zone as tzdata does), the program's `/` origin, or an argument or
    variable that is not valid UTF-8 (Windows has UTF-16 only)."""
    asked = "\0".join(case["args"] + list(case["env"]) + [v for v in case["env"].values() if v])
    said = [w for w in case["want"] if isinstance(w, str)]
    return ("$DIR" in asked or "HOME" in case["env"] or re.search("[\ud800-\udfff]|localtime|get_prog_origin|get_jq_origin|get_search_list", asked)
            or any("Is a directory" in w for w in said))


def check_cli(stury, diff, case):
    stdin = case["stdin"] if len(case["stdin"]) < 200 else case["stdin"][:200] + "..."
    files = f" files {case['files']}" if case["files"] else ""
    area, what = f"cli.tsv {case['area']}", f"cli.tsv:{case['line']}: stury {' '.join(case['args'])} <<< {stdin!r}{files}"
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
        usage = err.startswith(b"stury - commandline JSON processor") and err.endswith(b"For listing the command options, use stury --help.\n")
        why = None if (code, out) == (2, b"") and usage else f"exit {code} out {out!r} err {err!r}, want the usage and exit 2"
    else:
        want = run_tty("jq", opts, stdin_tty, stdout_tty, feed, env) if diff else None
        ok = code == 0 and out and out == (pinned or out) and (want is None or (code, out, err) == want)
        why = None if ok else f"exit {code} out {out!r} err {err!r}, jq {want or pinned}"
    return "terminal", f"terminal: {env} stury {' '.join(opts)} (stdin {'a terminal' if stdin_tty else 'piped'}, stdout {'a terminal' if stdout_tty else 'piped'})", why


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    diff = "--diff" in sys.argv
    stury = os.path.abspath(args[0] if args else "build/stury")
    # Every case runs in one time zone, a zone with daylight saving, which cli.tsv's date rows were recorded in.
    os.environ["TZ"] = "America/New_York"
    # Colours are each case's own choice, not the caller's.
    os.environ.pop("JQ_COLORS", None)
    os.environ.pop("NO_COLOR", None)
    if os.name == "nt":  # the console's code page cannot print every failure's bytes
        sys.stdout.reconfigure(errors="backslashreplace")
    if diff or "--record" in sys.argv:
        v = subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip()
        if v != "jq-1.8.2":
            sys.exit(f"--diff and --record need jq 1.8.2 on PATH, found {v or 'none'}")
    if "--record" in sys.argv:
        record_cli(os.path.join(HERE, "cli.tsv"))
    cases = parse_suite(os.path.join(SUITE, "jq.test")) + parse_suite(os.path.join(SUITE, "onig.test"))
    jobs = [(check_suite, case) for case in cases]
    jobs += [(check_fast_route, *row) for row in FAST_ROUTE]
    jobs += [(check_depth_refused, at) for at in DEEP_AT]
    jobs += [(check_repeated_root, f, text) for f in (".", ". | .", ".k") for text in REPEATED]
    jobs += [(check_spine_root, text, path, f) for text, path in SPINE_ROOTS for f in SPINE_FILTERS]
    jobs += [(check_spine_fault, text, path, f) for text, path in SPINE_FAULTS for f in SPINE_FAULT_FILTERS]
    jobs += [(check_spine_root, text, ["d", "k"], f, 6) for text, _ in DEEP_SPINES for f in ("-c .", "-c P", "P | length", "-c P[-1] | {id}")]
    jobs += [(check_spine_fault, text, ["d", "k"], f, 5) for text, _ in DEEP_SPINES for f in ("-c .", "-c P", "P | length", "-c P[].id")]
    jobs += [(check_stdin_file, o, t, f) for o, t in STDIN_FILES for f in STDIN_FILTERS]
    if os.name == "nt":
        print("memory, stdout closed, stdout nonblocking, deep pretty: skipped: they need POSIX descriptors or a memory reader", flush=True)
    else:
        jobs += [(check_reduce_memory, *row) for row in REDUCE_MEMORY]
        jobs += [(check_stdout_closed, f) for f in (["-c", "."], ["-c", ".a"], ["-c", "map(.)"], ["--unbuffered", "-c", "."])]
        jobs += [(check_stdout_nonblocking, *row) for row in NONBLOCKING]
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
