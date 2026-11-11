#!/usr/bin/env python3
"""A run over many files holds one file's memory at a time: the peak resident size over 40 copies of a file stays near
the peak over the first few, for NDJSON, a root array (the one-document route), CSV and -R, on one thread and on a pool
of fixed width. Each file is long enough to be answered in pieces on the pool's threads.

    memory_test.py [--odin PATH]
"""

import json
import os
import sys
import tempfile

from harness import build, odin_flag, peak
COPIES = 40
RECORDS = 100000
# The pool lane's width. A thread that takes part maps an arena of its own, so the peak depends on how many woke, and
# that varies with the host's load, by at most one arena for each thread past the first. The base run has twice as many
# files as the pool has threads, so every thread has had files to take before the peak is read.
POOL_WIDTH = 3
ARENA = 12 << 20
# The peak over many files may pass the peak over the base run by this many bytes.
SLACK = 8 << 20
# A schema check of one file of records holds no memory per record, and fmt --schema of a table holds the file and its
# converted text, not a document of it: the peak of either stays within a few times the file.
SCHEMA_PEAK = 64 << 20
# A stream of regex pieces over long strings that need decoding holds the pieces live, not what making them took: the
# peak of a count or a reduce over every piece of 400 bodies of about 3 KB stays under this.
PIECES_PEAK = 32 << 20
PIECE_FILTERS = ('[.[].body | splits(" +")] | length', 'reduce (.[].body | splits(" +")) as $p (0; . + 1)',
                 '[.[].body | scan("[a-z]+")] | length', '[.[].body | . as $s | range(0; length; 3) | $s[.:. + 3]] | length')
# schema sample holds one value at a time: the peak of a long run stays under this.
SAMPLE_PEAK = 16 << 20
SAMPLES = 200000
TABLE_SCHEMA = '{"type":"array","items":{"properties":{"id":{"type":"integer"},"ok":{"type":"boolean"}}}}'
SCHEMA = '{"properties":{"id":{"type":"integer"},"level":{"enum":["info","warn"]},"msg":{"type":"string","maxLength":200}}}'


def fixtures():
    """The three kinds of file, each about 10 MiB, as {name: text}."""
    rows = [f'{{"id":{i},"level":"info","msg":"request {i} served from the cache after a short wait","ok":true}}' for i in range(RECORDS)]
    csv = ["id,level,msg,ok"] + [f'{i},info,"request {i} served, from the cache",true' for i in range(RECORDS)]
    return {"ndjson": "\n".join(rows) + "\n", "json": "[" + ",\n".join(rows) + "]\n", "csv": "\n".join(csv) + "\n"}


def pieces_fixture():
    """An array of 400 records, each a body of about 3 KB with line breaks written as escapes."""
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "elit", "sed"]
    bodies = [{"id": i, "body": "\n".join(" ".join(words[(i + j + k) % len(words)] for k in range(60)) for j in range(8))} for i in range(400)]
    return json.dumps(bodies, separators=(",", ":"))


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
        # Per lane: the binary, the slack that the threads' arenas may add, and the file count of the base run.
        for threads, width in (("1 thread", 1), ("pool", POOL_WIDTH)):
            exes[threads] = (build(odin, os.path.join(tmp, "stury-" + threads.split()[0]), {"STURY_THREADS": width}), (width - 1) * ARENA, 2 * width - 1)
        paths = {}
        for kind, text in fixtures().items():
            first = os.path.join(tmp, f"{kind}-0")
            open(first, "w").write(text)
            paths[kind] = [first] + [os.path.join(tmp, f"{kind}-{i}") for i in range(1, COPIES)]
            for path in paths[kind][1:]:
                os.link(first, path)
        schema = os.path.join(tmp, "schema.json")
        open(schema, "w").write(SCHEMA)
        table = os.path.join(tmp, "table.json")
        open(table, "w").write(TABLE_SCHEMA)
        lanes = (("ndjson", ["-c", "."]), ("json", ["-c", "."]), ("csv", ["-c", "--from", "csv", "."]), ("ndjson", ["-R", "."]),
                 ("ndjson", ["check", "--schema", schema]), ("csv", ["fmt", "--schema", table, "--from", "csv", "--infer", "--to", "ndjson"]))
        pieces = os.path.join(tmp, "pieces.json")
        open(pieces, "w").write(pieces_fixture())
        for threads, (exe, arenas, base) in exes.items():
            held = peak_over(exe, ["schema", "sample", "-c", "--count", str(SAMPLES)], [schema])
            ok = held <= SAMPLE_PEAK
            print(f"{'ok  ' if ok else 'FAIL'} {threads:9} schema sample --count {SAMPLES} {held >> 20:4} MiB")
            if not ok:
                failed.append((threads, "schema sample"))
            for filter in PIECE_FILTERS:
                held = peak_over(exe, ["-c", filter], [pieces])
                ok = held <= PIECES_PEAK
                print(f"{'ok  ' if ok else 'FAIL'} {threads:9} pieces  {filter[:40]:40} {held >> 20:4} MiB")
                if not ok:
                    failed.append((threads, "pieces", filter))
            for kind, args in lanes:
                one, many = peak_over(exe, args, paths[kind][:base]), peak_over(exe, args, paths[kind])
                ok = many <= one + SLACK + arenas and (args[0] not in ("check", "fmt") or one <= SCHEMA_PEAK)
                print(f"{'ok  ' if ok else 'FAIL'} {threads:9} {kind:7} {' '.join(args):18} {base} files {one >> 20:4} MiB, {COPIES} files {many >> 20:4} MiB")
                if not ok:
                    failed.append((threads, kind, args))
    if failed:
        sys.exit(f"memory grows with the files: {failed}")
    print("memory ok")


main()
