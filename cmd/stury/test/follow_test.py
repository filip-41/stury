#!/usr/bin/env python3
"""`stury --follow FILTER FILE` answers each record as it is appended, holds a record cut short until its delimiter
arrives, reads a truncated file again from its start, and ends on SIGINT or SIGTERM by the signal, as jq does, on a
file, a FIFO and a pipe named /dev/stdin. Each answer is
read within a timeout while the process is still running, so an answer held until the file ends fails.

    follow_test.py [--odin PATH]
"""

import atexit
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

from harness import build, odin_flag
TIMEOUT = 5


class Follow:
    def __init__(self, exe, path, args, stdin=None):
        self.path = path
        self.proc = subprocess.Popen([exe, "--follow", *args, path], stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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

    def end(self, sig=signal.SIGTERM):
        self.proc.send_signal(sig)
        try:
            return self.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            sys.exit(f"did not end on {sig.name}")


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
    check(name + " exit", run.end(), -signal.SIGTERM)


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
    check("seq exit", run.end(), -signal.SIGTERM)
    check("seq last", run.get(), "\x1e6")


def stop_cases(exe, tmp):
    """A FIFO and a pipe named /dev/stdin wait in a read: a signal ends the run there too, promptly."""
    fifo = os.path.join(tmp, "fifo")
    os.mkfifo(fifo)
    for sig in (signal.SIGINT, signal.SIGTERM):
        for kind in ("fifo", "stdin"):
            name = f"{kind} {sig.name}"
            if kind == "fifo":
                run = Follow(exe, fifo, ["-c", ".a"])
                writer = open(fifo, "w")
            else:
                r, w = os.pipe()
                run = Follow(exe, "/dev/stdin", ["-c", ".a"], stdin=r)
                os.close(r)
                writer = os.fdopen(w, "w")
            writer.write('{"a":1}\n')
            writer.flush()
            check(name + " answer", run.get(), "1")
            check(name + " exit", run.end(sig), -sig)
            writer.close()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        exe = build(odin_flag(), os.path.join(tmp, "stury"))
        lines_case(exe, tmp, "ndjson", ["-c", "--from", "ndjson", ".a"], '{"a":1}\n', ('{"a":', '2}\n'), '{"a":3}\n', ["1", "2", "3"])
        lines_case(exe, tmp, "texts", ["-c", ".a"], '{"a":1}\n', ('{"a":\n', "2}\n"), '{"a":3} {"a":4}\n', ["1", "2", "3"])
        lines_case(exe, tmp, "raw", ["-R", "."], "one\n", ("tw", "o\n"), "three\n", ['"one"', '"two"', '"three"'])
        seq_case(exe, tmp)
        lines_case(exe, tmp, "csv", ["-c", "--from", "csv", "."], "k,v\na,1\n", ("b,", "2\n"), "k,v\nc,3\n", ['{"k":"a","v":"1"}', '{"k":"b","v":"2"}', '{"k":"c","v":"3"}'])
        lines_case(exe, tmp, "csv-path", ["--from", "csv", ".v"], "k,v\na,1\n", ('b,"x\n', 'y"\n'), "k,v\nc,3\n", ['"1"', '"x\\ny"', '"3"'])
        lines_case(exe, tmp, "csv-comment", ["-c", "--from", "csv", "--comment", "#", ".@comment"], "# t\nk,v\n#a\na,1\n", ("#b\nb,", "2\n"), "k,v\n#c\nc,3\n", ['["a"]', '["b"]', '["c"]'])
        # A signal ends the run by the signal, after an error too.
        path = os.path.join(tmp, "bad")
        open(path, "w").write('{"a":1}\n')
        run = Follow(exe, path, ["-c", "--from", "ndjson", ".a.b"])
        check("error text", run.get(run.errors), "stury: error (at " + path + ":1): Cannot index number with string (\"b\")")
        check("error exit", run.end(signal.SIGINT), -signal.SIGINT)
        stop_cases(exe, tmp)
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
