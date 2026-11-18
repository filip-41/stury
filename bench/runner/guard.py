import contextlib
import fcntl
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from typing import NamedTuple

import psutil

from .layout import BUILD

LOCK = BUILD / "timing.lock"
CAP_BYTES = 1 << 30
POLL_SECONDS = 0.005
LINUX = sys.platform.startswith("linux")


class Failed(Exception):
    """A child that exited non-zero, passed the memory cap, or ran past its time limit."""


class Run(NamedTuple):
    out: str
    err: str
    peak_mib: float


@contextlib.contextmanager
def locked():
    """Holds the lock exclusively for the block, waiting for another timed job to finish."""
    BUILD.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def over_cap(pid):
    """The pid, size and name of the first of `pid` and its descendants above the cap, else None."""
    try:
        proc = psutil.Process(pid)
        for p in [proc, *proc.children(recursive=True)]:
            with contextlib.suppress(psutil.Error):
                if p.memory_info().rss > CAP_BYTES:
                    return f"pid {p.pid} {p.name()} at {p.memory_info().rss >> 20} MiB"
    except psutil.Error:
        pass
    return None


def run(cmd, env=None, timeout=None, cwd=None):
    """Runs one command in a session of its own under the 1 GiB live RSS cap and returns its output and its peak RSS in
    MiB (from wait4), or raises Failed with why. A command over the cap or the time limit is killed with everything it
    started."""
    # Files rather than pipes: the wait loop does not read, and an answer past a pipe's buffer would block the child.
    out_file, err_file = tempfile.TemporaryFile("w+"), tempfile.TemporaryFile("w+")
    # An empty stdin, since a tool that reads stdin when it is open (dasel) would wait on a runner started in the
    # background.
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out_file, stderr=err_file, text=True, cwd=cwd, start_new_session=True,
                         env={**os.environ, **(env or {})})
    start = time.monotonic()
    while True:
        pid, status, usage = os.wait4(p.pid, os.WNOHANG)
        if pid == p.pid:
            break
        why = f"over the memory cap: {offender}" if (offender := over_cap(p.pid)) else \
            f"over {timeout} s" if timeout and time.monotonic() - start > timeout else ""
        if why:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(p.pid, signal.SIGKILL)
            os.wait4(p.pid, 0)
            raise Failed(why)
        time.sleep(POLL_SECONDS)
    out_file.seek(0)
    err_file.seek(0)
    out, err = out_file.read(), err_file.read()
    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        raise Failed((err.strip().splitlines() or ["exit %d" % code])[-1][:100])
    peak = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
    return Run(out, err, peak / (1 << 20))


def counts(cmd, events, env=None, timeout=None):
    """The counts of EVENTS (instructions, cycles) over one run of CMD, from `perf stat` on Linux and `/usr/bin/time -l`
    on macOS."""
    prefix = ["perf", "stat", "-x,", "-e", ",".join(events)] if LINUX else ["/usr/bin/time", "-l"]
    err = run(prefix + cmd, env, timeout).err
    found = []
    for event in events:
        if LINUX:
            m = re.search(rf"^(\d+),[^,]*,{event}", err, re.M)
        else:
            m = re.search(rf"(\d+)\s+{event} {'retired' if event == 'instructions' else 'elapsed'}", err)
        if not m:
            raise Failed(f"no {event} count")
        found.append(int(m.group(1)))
    return found
