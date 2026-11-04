#!/usr/bin/env python3
"""A run over many files holds one file's memory at a time: the peak resident size over 20 copies of a file stays near
the peak over one, for NDJSON, a root array (the one-document route), CSV and -R, on one thread and on the default
pool. Each file is long enough to be answered in pieces on the pool's threads.

    memory_test.py [--odin PATH]
"""

import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
COPIES = 20
RECORDS = 100000
# The peak over many files may pass the peak over one by this share and this many bytes: threads that join in later
# files take arenas of their own.
SHARE, SLACK = 1.5, 8 << 20


def fixtures():
    """The three kinds of file, each about 10 MiB, as {name: text}."""
    rows = [f'{{"id":{i},"level":"info","msg":"request {i} served from the cache after a short wait","ok":true}}' for i in range(RECORDS)]
    csv = ["id,level,msg,ok"] + [f'{i},info,"request {i} served, from the cache",true' for i in range(RECORDS)]
    return {"ndjson": "\n".join(rows) + "\n", "json": "[" + ",\n".join(rows) + "]\n", "csv": "\n".join(csv) + "\n"}


def peak(exe, args, files):
    """The most resident bytes a run of `exe` over `files` held."""
    proc = subprocess.Popen([exe, *args, *files], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    _, status, usage = os.wait4(proc.pid, 0)
    assert status == 0, (args, status, proc.stderr.read())
    # ru_maxrss is in bytes on macOS and in kibibytes elsewhere.
    return usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss << 10


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default="odin")
    odin = parser.parse_args().odin
    failed = []
    with tempfile.TemporaryDirectory() as tmp:
        exes = {}
        for threads, define in (("1 thread", ["-define:STURY_THREADS=1"]), ("default", [])):
            exes[threads] = os.path.join(tmp, "stury-" + threads.split()[0])
            subprocess.run([odin, "build", "cmd/stury", "-o:minimal", *define, f"-out:{exes[threads]}"], cwd=ROOT, check=True)
        paths = {}
        for kind, text in fixtures().items():
            first = os.path.join(tmp, f"{kind}-0")
            open(first, "w").write(text)
            paths[kind] = [first] + [os.path.join(tmp, f"{kind}-{i}") for i in range(1, COPIES)]
            for path in paths[kind][1:]:
                os.link(first, path)
        lanes = (("ndjson", ["-c", "."]), ("json", ["-c", "."]), ("csv", ["-c", "--from", "csv", "."]), ("ndjson", ["-R", "."]))
        for threads, exe in exes.items():
            for kind, args in lanes:
                one, many = peak(exe, args, paths[kind][:1]), peak(exe, args, paths[kind])
                ok = many <= one * SHARE + SLACK
                print(f"{'ok  ' if ok else 'FAIL'} {threads:9} {kind:7} {' '.join(args):18} 1 file {one >> 20:4} MiB, {COPIES} files {many >> 20:4} MiB")
                if not ok:
                    failed.append((threads, kind, args))
    if failed:
        sys.exit(f"memory grows with the files: {failed}")
    print("memory ok")


main()
