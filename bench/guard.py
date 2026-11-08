"""guard.py: the lock and the memory cap every benchmark runner and comparison script runs under.

LOCK is build/bench/timing.lock: one timed job runs at a time. CAP_KB is the live RSS above which a process is killed.
`over_cap(pid)` checks a process and its descendants and returns the offender as a string, else None. The library
runners (doc.py and the runners built on it) import `locked` and `over_cap`.

As a program, `python3 bench/guard.py COMMAND...` takes the lock, runs COMMAND in a session of its own, kills the whole
session when any process in it passes the cap, and exits with COMMAND's status. The command line comparisons
(bench/cli/*.sh) run themselves this way.
"""
import contextlib, fcntl, os, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.normpath(os.path.join(HERE, "..", "build", "bench"))
LOCK = os.path.join(BUILD, "timing.lock")
CAP_KB = 1024 * 1024
POLL_SECONDS = 0.02


@contextlib.contextmanager
def locked():
    """Holds LOCK exclusively for the block, waiting for another timed job to finish."""
    os.makedirs(BUILD, exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        yield


def over_cap(pid):
    """The pid, size and name of the first of `pid` and its descendants above CAP_KB, else None."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,comm="], capture_output=True, text=True).stdout
    rows, children = {}, {}
    for line in out.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 3:
            continue
        p, parent, rss = int(fields[0]), int(fields[1]), int(fields[2])
        rows[p] = (rss, fields[3] if len(fields) > 3 else "")
        children.setdefault(parent, []).append(p)
    pending = [pid]
    while pending:
        p = pending.pop()
        if p in rows and rows[p][0] > CAP_KB:
            return f"pid {p} {rows[p][1]} at {rows[p][0] // 1024} MiB"
        pending.extend(children.get(p, []))
    return None


def main(argv):
    if not argv:
        sys.exit("usage: python3 bench/guard.py COMMAND...")
    with locked():
        child = subprocess.Popen(argv, start_new_session=True)
        while child.poll() is None:
            if (offender := over_cap(child.pid)):
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                sys.exit(f"over the {CAP_KB // 1024} MiB memory cap: {offender}")
            time.sleep(POLL_SECONDS)
        return child.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
