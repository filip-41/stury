#!/usr/bin/env python3
"""A run on pieces answers as the serial run does: the same output, the same messages and the same exit status, at
every pool width, on records, a root array, a spine array and CSV, with a fault in the first, a middle and the last
piece. The serial reference never reaches the pool, and each pooled build cuts every input into many pieces.

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
    return '{"i":%d,"v":%d,"s":"r%d","o":{"k":[%d,true,null]}}' % (i, i * 7, i, i % 5)


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
CSV = [".id", "[.id, .qty]", "select(.qty | tonumber > 8000) | .name", "."]


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
        for f in FILTERS:
            out.append(["--from", "ndjson", "-c", f, nd])
            out.append(["-c", ".[] | " + f, arr])
        out.append(["-e", "--from", "ndjson", ".o.k[1]", nd])
        out.append(["--explain", "--from", "ndjson", "-c", ".v", nd])
        for f in SPINE:
            out.append(["-c", f, spine])
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
