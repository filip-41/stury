"""`stury --follow FILTER FILE` answers each record as it is appended, holds a record cut short until its delimiter
arrives, reads a truncated file again from its start, and ends on SIGINT or SIGTERM by the signal, as jq does, on a
file, a FIFO and a pipe named /dev/stdin. Each answer is read within a timeout while the process is still running, so an
answer held until the file ends fails."""

import os
import queue
import signal
import subprocess
import threading
import time

import pytest

TIMEOUT = 5

pytestmark = pytest.mark.skipif(os.name == "nt", reason="follows files and FIFOs by POSIX signals")


class Follow:
    def __init__(self, exe, path, args, stdin=None):
        self.path = path
        self.proc = subprocess.Popen([exe, "--follow", *args, path], stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.lines, self.errors = queue.Queue(), queue.Queue()
        for stream, sink in ((self.proc.stdout, self.lines), (self.proc.stderr, self.errors)):
            threading.Thread(target=lambda s=stream, k=sink: [k.put(line.rstrip("\n")) for line in s], daemon=True).start()

    def append(self, data):
        with open(self.path, "ab" if isinstance(data, bytes) else "a") as f:
            f.write(data)

    def get(self, sink=None):
        try:
            return (sink or self.lines).get(timeout=TIMEOUT)
        except queue.Empty:
            pytest.fail(f"no answer within {TIMEOUT}s from {self.path}")

    def expect_quiet(self, wait=0.4):
        time.sleep(wait)
        assert self.lines.empty(), f"answered a record that is not whole: {self.lines.get()}"

    def end(self, sig=signal.SIGTERM):
        self.proc.send_signal(sig)
        try:
            return self.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            pytest.fail(f"did not end on {sig.name}")


@pytest.fixture
def follow(stury):
    started = []

    def start(*args, **kw):
        started.append(Follow(stury, *args, **kw))
        return started[-1]

    yield start
    for run in started:
        run.proc.kill()
        run.proc.wait()


def write(path, data):
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


# (name, args, the file at the start, what is appended in two pieces, the file after a truncation, the three answers)
LINES = [
    ("ndjson", ["-c", "--from", "ndjson", ".a"], '{"a":1}\n', ('{"a":', '2}\n'), '{"a":3}\n', ["1", "2", "3"]),
    ("texts", ["-c", ".a"], '{"a":1}\n', ('{"a":\n', "2}\n"), '{"a":3} {"a":4}\n', ["1", "2", "3"]),
    ("raw", ["-R", "."], "one\n", ("tw", "o\n"), "three\n", ['"one"', '"two"', '"three"']),
    ("csv", ["-c", "--from", "csv", "."], "k,v\na,1\n", ("b,", "2\n"), "k,v\nc,3\n", ['{"k":"a","v":"1"}', '{"k":"b","v":"2"}', '{"k":"c","v":"3"}']),
    ("csv-path", ["--from", "csv", ".v"], "k,v\na,1\n", ('b,"x\n', 'y"\n'), "k,v\nc,3\n", ['"1"', '"x\\ny"', '"3"']),
    ("csv-comment", ["-c", "--from", "csv", "--comment", "#", ".@comment"], "# t\nk,v\n#a\na,1\n", ("#b\nb,", "2\n"), "k,v\n#c\nc,3\n", ['["a"]', '["b"]', '["c"]']),
    # A CBOR item ends where its own bytes say, and a 0x0A byte inside one is no line end.
    ("cbor", ["-c", "--from", "cbor", "."], b"\x82\x0a\x01", (b"\xa1\x61", b"\x61\x0a"), b"\x83\x01\x0a\x02", ["[10,1]", '{"a":10}', "[1,10,2]"]),
]


@pytest.mark.parametrize("name, args, first, cut, rest, answers", LINES, ids=[c[0] for c in LINES])
def test_follow_appended_records(follow, tmp_path, name, args, first, cut, rest, answers):
    """`first` is in the file when the run starts, `cut` is appended in two pieces, `rest` after a truncation."""
    path = str(tmp_path / name)
    write(path, first)
    run = follow(path, args)
    assert run.get() == answers[0]
    run.append(cut[0])
    run.expect_quiet()
    run.append(cut[1])
    assert run.get() == answers[1]
    write(path, rest)
    assert run.get(run.errors) == f"stury: {path}: file truncated"
    assert run.get() == answers[2]
    assert run.end() == -signal.SIGTERM


def test_follow_seq(follow, tmp_path):
    """A --seq record ends at the next separator, so each answer comes with the record after it, the last at the end."""
    path = str(tmp_path / "seq")
    write(path, '\x1e{"a":1}\n\x1e{"a":2}\n')
    run = follow(path, ["-c", "--seq", ".a"])
    assert run.get() == "\x1e1"
    run.expect_quiet()
    run.append('\x1e{"a":3}\n')
    assert run.get() == "\x1e2"
    write(path, '\x1e{"a":5}\n')
    assert run.get(run.errors) == f"stury: {path}: file truncated"
    run.append('\x1e{"a":6}\n')
    assert run.get() == "\x1e5"
    assert run.end() == -signal.SIGTERM
    assert run.get() == "\x1e6"


def test_follow_goes_on_past_a_bad_record(follow, tmp_path):
    """--follow skips a bad record without being asked, and still holds a record that is cut short."""
    path = str(tmp_path / "skip")
    write(path, '{"a":1}\n')
    run = follow(path, ["-c", "--from", "ndjson", ".a"])
    assert run.get() == "1"
    run.append("{bad}\n")
    assert run.get(run.errors) == f"stury: ignoring parse error: {path}:2:2: Object keys must be strings"
    run.append('{"a":')
    run.expect_quiet()
    run.append("2}\n")
    assert run.get() == "2"
    assert run.end() == -signal.SIGTERM


def test_follow_error_ends_by_signal(follow, tmp_path):
    """A signal ends the run by the signal, after an error too."""
    path = str(tmp_path / "bad")
    write(path, '{"a":1}\n')
    run = follow(path, ["-c", "--from", "ndjson", ".a.b"])
    assert run.get(run.errors) == "stury: error (at " + path + ":1): Cannot index number with string (\"b\")"
    assert run.end(signal.SIGINT) == -signal.SIGINT


@pytest.mark.parametrize("kind", ("fifo", "stdin"))
@pytest.mark.parametrize("sig", (signal.SIGINT, signal.SIGTERM), ids=lambda s: s.name)
def test_follow_waiting_read_ends_on_signal(follow, tmp_path, kind, sig):
    """A FIFO and a pipe named /dev/stdin wait in a read: a signal ends the run there too, promptly."""
    if kind == "fifo":
        fifo = str(tmp_path / "fifo")
        os.mkfifo(fifo)
        run = follow(fifo, ["-c", ".a"])
        writer = open(fifo, "w")
    else:
        r, w = os.pipe()
        run = follow("/dev/stdin", ["-c", ".a"], stdin=r)
        os.close(r)
        writer = os.fdopen(w, "w")
    with writer:
        writer.write('{"a":1}\n')
        writer.flush()
        assert run.get() == "1"
        assert run.end(sig) == -sig


@pytest.mark.parametrize("args, message", (
    ([], "--follow follows one named file"),
    (["-"], "--follow follows one named file"),
    (["{path}", "{path}"], "--follow follows one named file"),
    (["-s", "{path}"], "cannot be combined with --slurp"),
    (["-n", "{path}"], "cannot be combined with --null-input"),
    (["--stream", "{path}"], "cannot be combined with --stream"),
    (["--from", "json5", "{path}"], "--follow reads records"),
))
def test_follow_refuses(stury, tmp_path, args, message):
    path = str(tmp_path / "bad")
    write(path, '{"a":1}\n')
    done = subprocess.run([stury, "--follow", ".", *[a.format(path=path) for a in args]], capture_output=True, text=True)
    assert done.returncode == 2 and message in done.stderr, (done.returncode, done.stderr)


@pytest.mark.parametrize("sub", ("fmt", "check"))
def test_follow_refused_by_subcommand(stury, tmp_path, sub):
    path = str(tmp_path / "bad")
    write(path, '{"a":1}\n')
    done = subprocess.run([stury, sub, "--follow", path], capture_output=True, text=True)
    assert done.returncode == 2 and f"cannot be combined with {sub}" in done.stderr, (done.returncode, done.stderr)
