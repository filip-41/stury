"""Times the old tree's document lanes beside next/bench/doc on the same files.

Usage: python3 found_probe/run.py <old probe> <next probe> [FILE...]

Every lane's `check` and every count both probes print must agree before a file is timed; a mismatch exits non-zero
with the two values. Rounds interleave the two arms; each lane gets a GB/s table (best and median) and a peak RSS
table (min and median) with next's delta against the old tree in percent. RSS is the kernel's maximum for the child,
from wait4. The runner holds next/build/bench/timing.lock and kills a child over 1 GB of live RSS.
"""
import fcntl, os, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.normpath(os.path.join(HERE, "..", "..", "next"))
FIX = os.path.join(NEXT, "bench", "fixtures")
BUILD = os.path.join(NEXT, "build", "bench")
LOCK = os.path.join(BUILD, "timing.lock")
CAP_KB = 1024 * 1024
LANES = ("build", "read", "key")
COUNTS = ("answers", "objects", "records", "rows", "columns", "texts")


def path(name):
    for d in (FIX, os.path.join(FIX, "corpus")):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    if os.path.exists(name):
        return os.path.abspath(name)
    sys.exit(f"no fixture {name}")


def peak_mib(ru_maxrss):
    """Converts wait4's maximum RSS to MiB: bytes on macOS, KiB elsewhere."""
    peak_bytes = ru_maxrss if sys.platform == "darwin" else ru_maxrss * 1024
    return peak_bytes / (1024 * 1024)


def run(binary, lane, fixture):
    """Runs one arm once under the RSS cap and returns (gb_per_s, check, counts, peak MiB)."""
    p = subprocess.Popen([binary, lane, fixture], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=HERE)
    while True:
        pid, status, usage = os.wait4(p.pid, os.WNOHANG)
        if pid == p.pid:
            break
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
        if rss and int(rss) > CAP_KB:
            p.kill()
            _, killed, _ = os.wait4(p.pid, 0)
            p.returncode = os.waitstatus_to_exitcode(killed)
            p.communicate()
            sys.exit(f"over the memory cap: {binary} {lane} {fixture}")
        time.sleep(0.005)
    # wait4 reaped the child, so Popen must not wait again; its pipes still hold the output.
    p.returncode = os.waitstatus_to_exitcode(status)
    out, err = p.communicate()
    if p.returncode != 0:
        sys.exit(f"failed {binary} {lane} {fixture}: {err.strip()}")
    g = re.search(r"gb_per_s=([\d.eE+-]+)", out)
    c = re.search(r"check=(\d+)", out)
    if not g or not c:
        sys.exit(f"no gb_per_s or check from {binary} {lane} {fixture}: {out.strip()}")
    counts = {k: int(v) for k, v in re.findall(r"\b(" + "|".join(COUNTS) + r")=(\d+)", out)}
    return float(g.group(1)), int(c.group(1)), counts, peak_mib(usage.ru_maxrss)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    old, new = os.path.abspath(argv[0]), os.path.abspath(argv[1])
    files = argv[2:] or ["logs.json", "citm_catalog.json", "table.csv"]
    rounds = int(os.environ.get("ROUNDS") or 5)

    os.makedirs(BUILD, exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)

        # Every arm reads the same values or nothing is timed: one pass per arm and lane, compared first.
        for name in files:
            f = path(name)
            for lane in LANES:
                _, old_check, old_counts, _ = run(old, lane, f)
                _, new_check, new_counts, _ = run(new, lane, f)
                if old_check != new_check:
                    sys.exit(f"checksum disagrees on {name} {lane}: old={old_check} next={new_check}")
                shared = [k for k in COUNTS if k in old_counts and k in new_counts]
                for k in shared:
                    if old_counts[k] != new_counts[k]:
                        sys.exit(f"{k} disagrees on {name} {lane}: old={old_counts[k]} next={new_counts[k]}")
                shown = " ".join(f"{k}={old_counts[k]}" for k in shared)
                print(f"check {name:20} {lane:5} old={old_check} next={new_check}" + (f" {shown}" if shown else ""),
                      flush=True)

        gb = {(arm, name, lane): [] for arm in ("old", "next") for name in files for lane in LANES}
        rss = {(arm, name, lane): [] for arm in ("old", "next") for name in files for lane in LANES}
        for _ in range(rounds):
            for name in files:
                f = path(name)
                for lane in LANES:
                    order = (("old", old), ("next", new)) if len(gb["old", name, lane]) % 2 == 0 else (("next", new), ("old", old))
                    for arm, binary in order:
                        g, _, _, mib = run(binary, lane, f)
                        gb[arm, name, lane].append(g)
                        rss[arm, name, lane].append(mib)

        for lane in LANES:
            print(f"\n{lane} GB/s")
            print(f"{'file':20}{'old best':>10}{'next best':>10}{'best %':>9}{'old med':>10}{'next med':>10}{'med %':>9}")
            for name in files:
                o = gb["old", name, lane]
                n = gb["next", name, lane]
                ob, nb = max(o), max(n)
                om, nm = statistics.median(o), statistics.median(n)
                print(f"{name:20}{ob:10.3f}{nb:10.3f}{100 * (nb - ob) / ob:+9.2f}{om:10.3f}{nm:10.3f}"
                      f"{100 * (nm - om) / om:+9.2f}", flush=True)

            print(f"\n{lane} RSS MiB")
            print(f"{'file':20}{'old min':>10}{'next min':>10}{'min %':>9}{'old med':>10}{'next med':>10}{'med %':>9}")
            for name in files:
                o = rss["old", name, lane]
                n = rss["next", name, lane]
                ob, nb = min(o), min(n)
                om, nm = statistics.median(o), statistics.median(n)
                print(f"{name:20}{ob:10.2f}{nb:10.2f}{100 * (nb - ob) / ob:+9.2f}{om:10.2f}{nm:10.2f}"
                      f"{100 * (nm - om) / om:+9.2f}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
