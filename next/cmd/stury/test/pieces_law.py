#!/usr/bin/env python3
"""A run on pieces answers as the serial run does: the same output, the same messages and the same exit status, at
every pool width, on records, texts in the default framing, a root array, a spine array, an empty spine and CSV,
with a fault in the first, a middle and the last piece. The serial reference never reaches the pool, and each pooled
build cuts every input into many pieces.

    pieces_law.py [--odin PATH]
"""

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
WIDTHS = (1, 2, 6, 18)
# Pieces of a few records each.
SLICE = 256
COUNT = 3000
# `--explain`'s timings, its byte counts and its count of pieces differ between runs that answer alike.
UNSTABLE = re.compile(r"^stury: explain: (run_time|cost|compile_time):.*$|pieces=\S+", re.MULTILINE)


def build(odin, out, defines):
    cmd = [odin, "build", "cmd/stury", "-o:minimal", f"-out:{out}"] + [f"-define:{k}={v}" for k, v in defines.items()]
    subprocess.run(cmd, cwd=ROOT, check=True)
    return out


def record(i):
    return '{"i":%d,"v":%d,"s":"r%d\\u00e9\\/","o":{"k":[%d,true,null],"z":{}}}' % (i, i * 7, i, i % 5)


# The fault each input carries, at record `at`: a text that does not parse, or a record the filter fails on.
FAULTS = {"none": None, "first": 2, "middle": COUNT // 2, "last": COUNT - 2}


def records_text(at):
    lines = [record(i) if i != at else '{"i":%d,"v":01}' % i for i in range(COUNT)]
    return "\n".join(lines) + "\n"


def array_text(at, wrap):
    entries = [record(i) if i != at else '{"i":%d,"v":tru}' % i for i in range(COUNT)]
    body = "[" + ",".join(entries) + "]"
    return '{"n":1,"logs":%s,"tail":"x"}' % body if wrap else body


def csv_text(at):
    rows = ["id,qty,name"] + ['%d,%d,"n %d"' % (i, i * 3, i) if i != at else '%d,"7' % i for i in range(COUNT)]
    return "\n".join(rows) + "\n"


FILTERS = [".v", ".o.k[0]", ".v + 1", "select(.i % 97 == 0) | .s", "if .i == %d then error(\"x\") else .i end" % (COUNT // 3)]
SPINE = [".logs[].v", ".logs[] | .v + 1", ".logs[] | select(.i > 2900) | .s", ".logs[][]"]
# A filter collected over a root array's entries, and then a tail, with a fault or a jump inside the collected filter.
COLLECT = ["map(.v)", "[.[] | .s]", "[.[]]", "map(select(.i % 97 == 0)) | length", "map(.v) | add", "[.[] | .o.k[0]] | .[7]",
           "map(select(.i < 0))", "map(if .i == %d then error(\"x\") else .i end)" % (COUNT // 2),
           "map(if .i == %d then .s + 1 else .i end) | length" % (COUNT // 2), "map(limit(2; .o.k[]))", "map(first(.o.k[]))",
           "map(input)", "map($__loc__) | .[0]", "map(path(.o.k[]))", "map(getpath([\"o\", \"k\", 0]))",
           "map(reduce .o.k[] as $x (0; . + 1)) | add", "map([foreach .o.k[] as $x (0; . + 1)])",
           "map(label $out | .o.k[] | if . == true then break $out else . end)", "map(.o) | .[0]", ". | map(.i) | .[-1]"]
# The same over a spine array, and a collect's array printed under each printer option.
SPINE_COLLECT = [".logs | map(.v)", "[.logs[] | select(.i > 2900) | .s]", ".logs | map(.v) | length", "[.logs | .[] | .o]",
                 ".logs | map(error)"]
PRINTED = [["map(.o)"], ["--tab", "map(.s)"], ["--indent", "0", "map(.o)"], ["-S", "map(.o)"], ["--seq", "-c", "map(.i)"],
           ["-j", "map(.i)"], ["-a", "-c", "map(.s)"], ["-C", "-c", "map(.o)"], ["-e", "map(select(.i < 0))"], ["-e", "-c", "map(.i)"]]
CSV = [".id", "[.id, .qty]", "select(.qty | tonumber > 8000) | .name", "."]
# The whole text printed or counted, under each printer option.
WHOLE = [["."], ["-c", "."], ["--tab", "."], ["--indent", "1", "."], ["--indent", "0", "."], ["-S", "."], ["--seq", "-c", "."],
         ["-j", "."], ["-a", "-c", "."], ["-C", "-c", "."], ["-e", "-c", "."], ["length"], ["fmt"], ["fmt", "--tab"],
         ["fmt", "--check"]]
# Filters over the whole document, which build it on the pool's threads.
DOCUMENT = ["group_by(.i % 5) | map([.[0].o.k[0], length])", "reduce .[] as $r (0; . + $r.v)", "sort_by(-.i) | .[0:2]",
            "[paths] | length", "to_entries | .[-1]"]
SPINE_DOCUMENT = [".logs | group_by(.i % 5) | map([.[0].o.k[0], length])", "reduce .logs[] as $r (0; . + $r.v)",
                  "[.n, .tail, (.logs | length)]", "del(.logs) | keys"]
# Entries nested `DEPTH` deep under the root array, one of them a level deeper at the fault's place.
DEPTH = 40


def nested_text(at):
    entries = ["[" * (DEPTH + (i == at)) + str(i) + "]" * (DEPTH + (i == at)) for i in range(COUNT // 4)]
    return "[" + ",".join(entries) + "]"


def cases(directory):
    """Each run, as the arguments after the binary."""
    out = []

    def file(name, text):
        path = os.path.join(directory, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    for fault, at in FAULTS.items():
        nd = file(f"records-{fault}.ndjson", records_text(at))
        arr = file(f"array-{fault}.json", array_text(at, False))
        spine = file(f"spine-{fault}.json", array_text(at, True))
        table = file(f"table-{fault}.csv", csv_text(at))
        # Many texts in the default framing, one to a line and run on with spaces.
        texts = file(f"texts-{fault}.json", records_text(at).replace("\n", " \n  ", COUNT // 2))
        for f in FILTERS:
            out.append(["--from", "ndjson", "-c", f, nd])
            out.append(["-c", ".[] | " + f, arr])
            out.append(["-c", f, texts])
        out.append(["-e", "--from", "ndjson", ".o.k[1]", nd])
        out.append(["--explain", "--from", "ndjson", "-c", ".v", nd])
        for f in SPINE:
            out.append(["-c", f, spine])
        for f in COLLECT:
            out.append(["-c", f, arr])
        for f in SPINE_COLLECT:
            out.append(["-c", f, spine])
        for p in PRINTED:
            out.append(p + [arr])
        out.append(["--explain", "-c", "map(.v) | length", arr])
        out.append(["--explain", "-c", ".logs | map(.v)", spine])
        for w in WHOLE:
            out.append(w + [arr])
            out.append(w + [spine])
        out.append(["-c", ".logs | length", spine])
        for f in DOCUMENT:
            out.append(["-c", f, arr])
        for f in SPINE_DOCUMENT:
            out.append(["-c", f, spine])
        nested = file(f"nested-{fault}.json", nested_text(at if at is None else at // 4))
        out.append(["--max-depth", str(DEPTH + 1), "-c", "flatten | add", nested])
        out.append(["--max-depth", str(DEPTH + 2), "-c", "flatten | add", nested])
        out.append(["--explain", "-c", ".", arr])
        out.append(["--explain", "length", spine])
        out.append(["--explain", "-c", ".logs[].v", spine])
        out.append(["--explain", "-c", ".[] | .v + 1", arr])
        out.append(["--explain", "--from", "csv", "-c", ".id", table])
        for f in CSV:
            out.append(["--from", "csv", "-c", f, table])
        out.append(["--from", "csv", "--to", "csv", "{id, qty}", table])
        out.append(["check", nd])
    # The spine names one key twice, and jq reads the last.
    twice = file("twice.json", '{"logs":%s,"logs":[1,2]}' % array_text(None, False))
    out.append(["-c", ".logs[]", twice])
    out.append(["-c", ".logs[].v?", twice])
    # A key repeated in an entry, and at the root around the array.
    entries = [record(i) if i % 1000 != 7 else '{"i":%d,"i":0,"v":1}' % i for i in range(COUNT)]
    repeated = file("repeated.json", '{"n":1,"logs":[%s],"n":2}' % ",".join(entries))
    out.append(["-c", ".logs | length", twice])
    out.append(["-c", ".logs | map(.v)", twice])
    out.append(["-c", "[.logs[] | .i]", repeated])
    for f in SPINE_DOCUMENT:
        out.append(["-c", f, twice])
        out.append(["-c", f, repeated])
    out.append(["-c", "[.logs[] | .i] | add", repeated])
    # Spines with no entries, and a root object whose length is its count of keys.
    empty = file("empty.json", '{"n":1,"logs":[%s],"tail":"x"}' % (" " * (SLICE * 16)))
    blank = file("blank.json", "[%s]" % ("\n" * (SLICE * 16)))
    keys = file("keys.json", "{%s}" % ",".join('"k%d":%s' % (i, record(i)) for i in range(COUNT)))
    for w in WHOLE:
        out.append(w + [twice])
        out.append(w + [repeated])
        out.append(w + [empty])
        out.append(w + [blank])
    out.append(["-c", ".logs | length", empty])
    out.append(["length", keys])
    out.append(["-c", "keys | length", keys])
    return out


# Where a run on an input with no fault must have taken pieces.
POOLED = re.compile(r"pieces=[1-9]")


def run(binary, args):
    try:
        done = subprocess.run([binary] + args, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return b"", "timed out", None
    return done.stdout, UNSTABLE.sub("", done.stderr.decode(errors="replace")), done.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        serial = {"STURY_POOLED_BYTES": 1 << 62}
        builds = {"serial": serial} | {w: {"STURY_THREADS": w, "STURY_POOLED_BYTES": 0, "RECORDS_SLICE": SLICE} for w in WIDTHS}
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            binaries = dict(zip(builds, pool.map(lambda kv: build(args.odin, os.path.join(directory, f"stury-{kv[0]}"), kv[1]), builds.items())))
        failures = 0
        runs = cases(directory)
        for case in runs:
            want = run(binaries["serial"], case)
            for w in WIDTHS:
                got = run(binaries[w], case)
                if got != want:
                    failures += 1
                    what = [name for name, a, b in zip(("stdout", "stderr", "status"), got, want) if a != b]
                    print(f"FAIL threads={w} {' '.join(what)}: stury {' '.join(os.path.basename(a) for a in case)}")
            if "--explain" in case and case[-1].endswith("-none" + os.path.splitext(case[-1])[1]):
                stderr = subprocess.run([binaries[WIDTHS[-1]]] + case, capture_output=True).stderr.decode()
                if not POOLED.search(stderr):
                    failures += 1
                    print(f"FAIL no pieces: stury {' '.join(os.path.basename(a) for a in case)}")
        print(f"{len(runs)} runs at {len(WIDTHS)} widths, {failures} differ from the serial run")
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
