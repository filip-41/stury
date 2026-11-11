#!/usr/bin/env python3
"""A run over many files holds one file's memory at a time: the peak resident size over 20 copies of a file stays near
the peak over one, for NDJSON, a root array (the one-document route), CSV and -R, on one thread and on the default
pool. Each file is long enough to be answered in pieces on the pool's threads.

    memory_test.py [--odin PATH]
"""

import os
import sys
import tempfile

from harness import build, odin_flag, peak
COPIES = 20
RECORDS = 100000
# The peak over many files may pass the peak over one by this share and this many bytes: threads that join in later
# files take arenas of their own.
SHARE, SLACK = 1.5, 8 << 20
# A schema check of one file of records holds no memory per record: its peak stays within a few times the file.
CHECK_PEAK = 64 << 20
SCHEMA = '{"properties":{"id":{"type":"integer"},"level":{"enum":["info","warn"]},"msg":{"type":"string","maxLength":200}}}'


def fixtures():
    """The three kinds of file, each about 10 MiB, as {name: text}."""
    rows = [f'{{"id":{i},"level":"info","msg":"request {i} served from the cache after a short wait","ok":true}}' for i in range(RECORDS)]
    csv = ["id,level,msg,ok"] + [f'{i},info,"request {i} served, from the cache",true' for i in range(RECORDS)]
    return {"ndjson": "\n".join(rows) + "\n", "json": "[" + ",\n".join(rows) + "]\n", "csv": "\n".join(csv) + "\n"}


def peak_over(exe, args, files):
    """The most resident bytes a run of `exe` over `files` held."""
    status, err, held = peak([exe, *args, *files])
    assert status == 0, (args, status, err)
    return held


def main():
    odin = odin_flag()
    failed = []
    with tempfile.TemporaryDirectory() as tmp:
        exes = {}
        for threads, define in (("1 thread", {"STURY_THREADS": 1}), ("default", {})):
            exes[threads] = build(odin, os.path.join(tmp, "stury-" + threads.split()[0]), define)
        paths = {}
        for kind, text in fixtures().items():
            first = os.path.join(tmp, f"{kind}-0")
            open(first, "w").write(text)
            paths[kind] = [first] + [os.path.join(tmp, f"{kind}-{i}") for i in range(1, COPIES)]
            for path in paths[kind][1:]:
                os.link(first, path)
        schema = os.path.join(tmp, "schema.json")
        open(schema, "w").write(SCHEMA)
        lanes = (("ndjson", ["-c", "."]), ("json", ["-c", "."]), ("csv", ["-c", "--from", "csv", "."]), ("ndjson", ["-R", "."]),
                 ("ndjson", ["check", "--schema", schema]))
        for threads, exe in exes.items():
            for kind, args in lanes:
                one, many = peak_over(exe, args, paths[kind][:1]), peak_over(exe, args, paths[kind])
                ok = many <= one * SHARE + SLACK and (args[0] != "check" or one <= CHECK_PEAK)
                print(f"{'ok  ' if ok else 'FAIL'} {threads:9} {kind:7} {' '.join(args):18} 1 file {one >> 20:4} MiB, {COPIES} files {many >> 20:4} MiB")
                if not ok:
                    failed.append((threads, kind, args))
    if failed:
        sys.exit(f"memory grows with the files: {failed}")
    print("memory ok")


main()
