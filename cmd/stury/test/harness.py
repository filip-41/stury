"""What the command line's test scripts share: building stury, running it under a time and memory cap, and reading
the peak a run held."""

import argparse
import ctypes
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
# Megabytes a case may hold; macOS enforces no RLIMIT_AS, so a runaway case such as `[repeat(1)]` would
# otherwise take tens of GB before its timeout stops it.
MEM_CAP_MB = int(os.environ.get("STURY_TEST_MEM_MB", "3000"))
# The resident megabytes all live children may hold before a new one waits to start.
RSS_BUDGET_MB = int(os.environ.get("STURY_TEST_RSS_BUDGET_MB", "5000"))


def odin_flag():
    """The `--odin PATH` a build script is given."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    return parser.parse_args().odin


def build(odin, out, defines={}):
    """stury at -o:minimal with `defines` set, written to `out`."""
    cmd = [odin, "build", "cmd/stury", "-o:minimal", f"-out:{out}"] + [f"-define:{k}={v}" for k, v in defines.items()]
    subprocess.run(cmd, cwd=ROOT, check=True)
    return out


STURY_FOOTER = b"Use stury --help for help with command-line options,\nor see stury(1), or docs/cli.md at https://github.com/filip-41/stury\n"
JQ_FOOTER = b"Use jq --help for help with command-line options,\nor see the jq manpage, or online docs at https://jqlang.org\n"


def as_jq(stderr):
    """stury's messages with jq's program name, and its usage footer, which names stury's pages, as jq's."""
    return re.sub(rb"(?m)^stury: ", b"jq: ", stderr).replace(STURY_FOOTER, JQ_FOOTER)


# Linux starts a forked child's peak at the resident size of the process that forked it, and a test script holds its
# inputs, so there a run is forked from a fresh interpreter, which writes the run's wait status and peak to fd ARGV[1].
FORK_FRESH = sys.platform == "linux"
FRESH_FORK = """import os, resource, sys
report, cpu = int(sys.argv[1]), int(sys.argv[2])
if cpu:
    resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
pid = os.fork()
if pid == 0:
    os.close(report)
    try:
        os.execvp(sys.argv[3], sys.argv[3:])
    finally:
        os._exit(127)
_, status, usage = os.wait4(pid, 0)
os.write(report, b"%d %d" % (status, usage.ru_maxrss))
"""


def peak(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, cpu=None):
    """(exit status, stderr, peak resident bytes) of a run, read from its rusage, with at most `cpu` seconds of CPU.
    `stdin` given as bytes is written through a pipe."""
    import resource  # POSIX only

    fed = isinstance(stdin, bytes)
    source = subprocess.PIPE if fed else stdin
    if FORK_FRESH:
        report, written = os.pipe()
        fresh = [sys.executable, "-I", "-c", FRESH_FORK, str(written), str(cpu or 0), *argv]
        p = subprocess.Popen(fresh, stdin=source, stdout=stdout, stderr=stderr, pass_fds=(written,))
        os.close(written)
    else:
        limit = (lambda: resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))) if cpu else None
        p = subprocess.Popen(argv, stdin=source, stdout=stdout, stderr=stderr, preexec_fn=limit)
    err = []
    reader = p.stderr and threading.Thread(target=lambda: err.append(p.stderr.read()))
    reader and reader.start()
    if fed:
        try:
            p.stdin.write(stdin)
        except BrokenPipeError:
            pass
        p.stdin.close()
    if FORK_FRESH:
        p.wait()
        with os.fdopen(report, "rb") as f:
            said = f.read().split()
        if len(said) != 2:
            raise RuntimeError(f"the fresh fork of {argv[0]} exited {p.returncode} without its report")
        status, maxrss = map(int, said)
    else:
        _, status, usage = os.wait4(p.pid, 0)
        maxrss = usage.ru_maxrss
    p.returncode = os.waitstatus_to_exitcode(status)
    reader and reader.join()
    # ru_maxrss is in bytes on macOS and in kibibytes elsewhere.
    return p.returncode, b"".join(err), maxrss if sys.platform == "darwin" else maxrss << 10


def resident_mb(pid):
    """Process `pid`'s resident megabytes, read without starting a process (a `ps` per poll would stall the suite's
    stdin feeds); 0 when it is gone or the platform has no reader."""
    if sys.platform == "darwin":
        info = (ctypes.c_uint64 * 12)()  # struct proc_taskinfo; pti_resident_size is its second field
        n = _libproc.proc_pidinfo(pid, 4, 0, info, ctypes.sizeof(info))  # PROC_PIDTASKINFO
        return info[1] >> 20 if n == ctypes.sizeof(info) else 0
    if os.name == "nt":
        counters = (ctypes.c_size_t * 9)()  # PROCESS_MEMORY_COUNTERS on 64 bits: cb and the fault count share the first slot
        counters[0] = ctypes.sizeof(counters)
        h = _kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return 0
        try:
            return counters[2] >> 20 if _kernel32.K32GetProcessMemoryInfo(h, counters, ctypes.sizeof(counters)) else 0
        finally:
            _kernel32.CloseHandle(h)
    try:
        with open(f"/proc/{pid}/statm") as f:
            return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") >> 20
    except (OSError, IndexError, ValueError):
        return 0


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
_kernel32 = ctypes.WinDLL("kernel32") if os.name == "nt" else None
if _kernel32:
    _kernel32.OpenProcess.restype = ctypes.c_void_p
    _kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    _kernel32.K32GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    _kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
_live = set()
_live_lock = threading.Lock()


def start_when_budget_allows(argv, **kw):
    """Popen of a child, started once the live children's resident sum is under RSS_BUDGET_MB (or none is live).
    The lock covers the sum and the set, not the spawn: under it, the workers started their children one at a
    time. A child a few ms old is not yet in another worker's sum, and holds nothing yet."""
    while True:
        with _live_lock:
            allowed = not _live or sum(resident_mb(q) for q in _live) <= RSS_BUDGET_MB
        if allowed:
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
            with _live_lock:
                _live.add(p.pid)
            return p
        time.sleep(0.05)


def run_capped(argv, input, timeout, cap_mb=MEM_CAP_MB, **kw):
    """subprocess.run with capture, killing the child past `timeout` or `cap_mb` resident; either raises
    subprocess.TimeoutExpired. One communicate() call: a retried one stops feeding stdin."""
    p = start_when_budget_allows(argv, **kw)
    done, over = threading.Event(), threading.Event()

    def watch():
        while not done.wait(0.05):
            if resident_mb(p.pid) > cap_mb:
                over.set()
                p.kill()
                return

    threading.Thread(target=watch, daemon=True).start()
    try:
        out, err = p.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise
    finally:
        done.set()
        with _live_lock:
            _live.discard(p.pid)
    if over.is_set():
        raise subprocess.TimeoutExpired(argv, timeout)
    return subprocess.CompletedProcess(argv, p.returncode, out, err)


def passing(stury, schema, path, count, flags=(), timeout=60, cap_mb=1024):
    """The indices of the first `count` lines of `path` that pass `schema` under `stury check` with `flags`."""
    p = run_capped([stury, "check", *flags, "--schema", schema, path], None, timeout, cap_mb=cap_mb)
    failed = {int(m) - 1 for m in re.findall(rf"^{re.escape(path)}:(\d+):", p.stderr.decode(errors="replace"), re.M)}
    return [i for i in range(count) if i not in failed]


def fixtures_dir():
    """bench/fixtures of the main checkout, which its worktrees share."""
    common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return os.path.join(os.path.dirname(os.path.abspath(os.path.join(ROOT, common))), "bench/fixtures")
