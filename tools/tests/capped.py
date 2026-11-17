"""Running stury under a time and memory cap, and reading the peak a run held."""

import ctypes
import errno
import json
import os
import re
import shutil
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# macOS enforces no RLIMIT_AS, so a runaway case such as `[repeat(1)]` would take tens of GB before its timeout.
MEM_CAP_MB = int(os.environ.get("STURY_TEST_MEM_MB", "3000"))
# Seconds a case may take. A sanitized build needs more.
TIMEOUT = float(os.environ.get("STURY_TEST_TIMEOUT", "10"))
# `address` or `thread` for a sanitized build (make test-asan, test-tsan), else empty.
SANITIZER = os.environ.get("STURY_SANITIZER", "")
# A sanitizer's memory and CPU measures are its own, so only answers count.
SANITIZED = bool(os.environ.get("STURY_SANITIZED"))


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

# The bytes an empty pipe takes without blocking (POSIX's PIPE_BUF, which Windows' pipes exceed).
PIPE_TAKES = 512


def feed(stdin, input):
    """Writes `input` and closes `stdin`. A child that stops reading closes the pipe, and close() closes it even when
    its flush fails."""
    for step in (lambda: input and stdin.write(input), stdin.close):
        try:
            step()
        except OSError as e:
            # Windows reports a write to a pipe the child closed as EINVAL.
            if not isinstance(e, BrokenPipeError) and e.errno != errno.EINVAL:
                raise


def run_capped(argv, input, timeout, cap_mb=MEM_CAP_MB, **kw):
    """subprocess.run with capture, killing the child past `timeout` or `cap_mb` resident, either as TimeoutExpired.
    communicate() writes PIPE_TAKES bytes per turn, so a longer input is written whole on a thread of its own."""
    # An executable path and close_fds=False let subprocess posix_spawn the child where otherwise it forks this process.
    p = subprocess.Popen(argv, executable=shutil.which(argv[0]) or argv[0], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, close_fds=False, **kw)
    done, over = threading.Event(), threading.Event()

    def watch():
        while not done.wait(0.05):
            if resident_mb(p.pid) > cap_mb:
                over.set()
                p.kill()
                return

    threading.Thread(target=watch, daemon=True).start()
    stdin, p.stdin = p.stdin, None
    if input and len(input) > PIPE_TAKES:
        threading.Thread(target=feed, args=(stdin, input), daemon=True).start()
    else:
        feed(stdin, input)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise
    finally:
        done.set()
    if over.is_set():
        raise subprocess.TimeoutExpired(argv, timeout)
    return subprocess.CompletedProcess(argv, p.returncode, out, err)


def outcome(argv, input, timeout=TIMEOUT, **kw):
    """(exit status, stdout, stderr) of run_capped, or ("timeout", b"", b"") past its time or memory cap."""
    try:
        p = run_capped(argv, input, timeout, **kw)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""


def values(text, decoder=json.JSONDecoder()):
    """The JSON values of a text, one after another."""
    out, at = [], 0
    while True:
        while at < len(text) and text[at] in " \t\r\n":
            at += 1
        if at >= len(text):
            return out
        value, at = decoder.raw_decode(text, at)
        out.append(value)


def passing(stury, schema, path, count, flags=(), timeout=60, cap_mb=1024):
    """The indices of the first `count` lines of `path` that pass `schema` under `stury check` with `flags`."""
    p = run_capped([stury, "check", *flags, "--schema", schema, path], None, timeout, cap_mb=cap_mb)
    failed = {int(m) - 1 for m in re.findall(rf"^{re.escape(path)}:(\d+):", p.stderr.decode(errors="replace"), re.M)}
    return [i for i in range(count) if i not in failed]


def fixtures_dir():
    """bench/fixtures of the main checkout, which its worktrees share."""
    common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return os.path.join(os.path.dirname(os.path.abspath(os.path.join(ROOT, common))), "bench/fixtures")
