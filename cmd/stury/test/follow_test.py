#!/usr/bin/env python3
"""`stury --follow FILTER FILE` answers each record as it is appended, holds a record cut short until its delimiter
arrives, reads a truncated file again from its start, and ends on SIGTERM with a run's exit status. Each answer is
read within a timeout while the process is still running, so an answer held until the file ends fails.

    follow_test.py [--odin PATH]
"""

import argparse
import atexit
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
TIMEOUT = 5


class Follow:
    def __init__(self, exe, path, args):
        self.path = path
        self.proc = subprocess.Popen([exe, "--follow", *args, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        atexit.register(self.proc.kill)
        self.lines = queue.Queue()
        self.errors = queue.Queue()
        for stream, sink in ((self.proc.stdout, self.lines), (self.proc.stderr, self.errors)):
            threading.Thread(target=lambda s=stream, k=sink: [k.put(line.rstrip("\n")) for line in s], daemon=True).start()

    def append(self, data):
        with open(self.path, "a") as f:
            f.write(data)

    def get(self, sink=None):
        try:
            return (sink or self.lines).get(timeout=TIMEOUT)
        except queue.Empty:
            self.proc.kill()
            sys.exit(f"no answer within {TIMEOUT}s from {self.path}")

    def expect_quiet(self, wait=0.4):
        time.sleep(wait)
        assert self.lines.empty(), f"answered a record that is not whole: {self.lines.get()}"

    def end(self):
        self.proc.send_signal(signal.SIGTERM)
        try:
            return self.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            sys.exit("did not end on SIGTERM")


def check(name, got, want):
    if got != want:
        sys.exit(f"{name}: got {got!r}, want {want!r}")


def lines_case(exe, tmp, name, args, first, cut, rest, answers):
    """`first` is in the file when the run starts, `cut` is appended in two pieces, `rest` after a truncation."""
    path = os.path.join(tmp, name)
    open(path, "w").write(first)
    run = Follow(exe, path, args)
    check(name + " first", run.get(), answers[0])
    run.append(cut[0])
    run.expect_quiet()
    run.append(cut[1])
    check(name + " cut record", run.get(), answers[1])
    open(path, "w").write(rest)
    check(name + " truncated", run.get(run.errors), f"stury: {path}: file truncated")
    check(name + " after truncation", run.get(), answers[2])
    check(name + " exit", run.end(), 0)


def seq_case(exe, tmp):
    """A --seq record ends at the next separator, so each answer comes with the record after it, the last at the end."""
    path = os.path.join(tmp, "seq")
    open(path, "w").write('\x1e{"a":1}\n\x1e{"a":2}\n')
    run = Follow(exe, path, ["-c", "--seq", ".a"])
    check("seq first", run.get(), "\x1e1")
    run.expect_quiet()
    run.append('\x1e{"a":3}\n')
    check("seq second", run.get(), "\x1e2")
    open(path, "w").write('\x1e{"a":5}\n')
    check("seq truncated", run.get(run.errors), f"stury: {path}: file truncated")
    run.append('\x1e{"a":6}\n')
    check("seq after truncation", run.get(), "\x1e5")
    check("seq exit", run.end(), 0)
    check("seq last", run.get(), "\x1e6")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default="odin")
    odin = parser.parse_args().odin
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, "stury")
        subprocess.run([odin, "build", "cmd/stury", "-o:minimal", f"-out:{exe}"], cwd=ROOT, check=True)
        lines_case(exe, tmp, "ndjson", ["-c", "--from", "ndjson", ".a"], '{"a":1}\n', ('{"a":', '2}\n'), '{"a":3}\n', ["1", "2", "3"])
        lines_case(exe, tmp, "texts", ["-c", ".a"], '{"a":1}\n', ('{"a":\n', "2}\n"), '{"a":3} {"a":4}\n', ["1", "2", "3"])
        lines_case(exe, tmp, "raw", ["-R", "."], "one\n", ("tw", "o\n"), "three\n", ['"one"', '"two"', '"three"'])
        seq_case(exe, tmp)
        lines_case(exe, tmp, "csv", ["-c", "--from", "csv", "."], "k,v\na,1\n", ("b,", "2\n"), "k,v\nc,3\n", ['{"k":"a","v":"1"}', '{"k":"b","v":"2"}', '{"k":"c","v":"3"}'])
        lines_case(exe, tmp, "csv-path", ["--from", "csv", ".v"], "k,v\na,1\n", ('b,"x\n', 'y"\n'), "k,v\nc,3\n", ['"1"', '"x\\ny"', '"3"'])
        # The status of a run is the one after the records it answered.
        path = os.path.join(tmp, "bad")
        open(path, "w").write('{"a":1}\n')
        run = Follow(exe, path, ["-c", "--from", "ndjson", ".a.b"])
        check("error text", run.get(run.errors), "stury: error (at " + path + ":1): Cannot index number with string (\"b\")")
        check("error exit", run.end(), 5)
        # What it refuses.
        for args, message in (
            ([], "--follow follows one named file"),
            (["-"],"--follow follows one named file"),
            ([path, path], "--follow follows one named file"),
            (["-s", path], "cannot be combined with --slurp"),
            (["-n", path], "cannot be combined with --null-input"),
            (["--stream", path], "cannot be combined with --stream"),
            (["--from", "json5", path], "--follow reads records"),
        ):
            done = subprocess.run([exe, "--follow", ".", *args], capture_output=True, text=True)
            assert done.returncode == 2 and message in done.stderr, (args, done.returncode, done.stderr)
        for sub in ("fmt", "check"):
            args, message = [exe, sub, "--follow", path], f"cannot be combined with {sub}"
            done = subprocess.run(args, capture_output=True, text=True)
            assert done.returncode == 2 and message in done.stderr, (args, done.returncode, done.stderr)
        print("follow ok")


main()
