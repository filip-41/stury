"""Times every case of the kernel bench: wall time per unit over interleaved rounds, then instructions and cycles per
unit from the difference between R and 2R reps, which cancels the setup.

Usage: python3 -I run.py <bench binary> [rounds]. Every child runs under an RSS cap.
Env: CASES=<regex> keeps the cases whose name matches, COUNT=0 skips the counted pass (no perf counters).
Counts come from `/usr/bin/time -l` on macOS and `perf stat` on Linux."""
import os, re, statistics, subprocess, sys, time

CAP_MB = 512
BIN = sys.argv[1]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 7
COUNT = os.environ.get("COUNT", "1") != "0"
KEEP = re.compile(os.environ.get("CASES", "."))
LINUX = sys.platform.startswith("linux")

# (name, case, reps, arg)
CASES = [("pack 16/256", "pack", 20000, 16)]
CASES += [(f"skip 1/{every}", "skip", 2048, every) for every in (256, 1024, 4096)]
CASES += [(f"tail {n}", "tail", max(1, (1 << 28) // (4096 * n)), n) for n in (24, 72, 200, 1000)]
CASES = [c for c in CASES if KEEP.search(c[0])]


def run_capped(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    while p.poll() is None:
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
        if rss and int(rss) > CAP_MB * 1024:
            p.kill()
            sys.exit(f"killed {cmd}: over {CAP_MB} MB")
        time.sleep(0.01)
    out, err = p.communicate()
    if p.returncode != 0:
        sys.exit(f"failed {cmd}: {err}")
    return out, err


def timed(case, reps, arg):
    out, _ = run_capped([BIN, case, str(reps), str(arg)])
    sink, ns, units = re.search(r"sink=(\d+) ns=([\d.]+) units=(\d+)", out).groups()
    return int(sink), float(ns), int(units)


def counted(case, reps, arg):
    prefix = ["perf", "stat", "-x,", "-e", "instructions,cycles"] if LINUX else ["/usr/bin/time", "-l"]
    _, err = run_capped(prefix + [BIN, case, str(reps), str(arg)])
    if LINUX:
        get = lambda key: int(re.search(r"^(\d+),[^,]*," + key, err, re.M).group(1))
        return get("instructions"), get("cycles")
    get = lambda key: int(re.search(r"(\d+)\s+" + key, err).group(1))
    return get("instructions retired"), get("cycles elapsed")


ns = {c[0]: [] for c in CASES}
units = {}
for _ in range(ROUNDS):
    for name, case, reps, arg in CASES:
        _, t, units[name] = timed(case, reps, arg)
        ns[name].append(t)

for name, case, reps, arg in CASES:
    line = f"{name:12} ns {statistics.median(ns[name]):8.3f} (best {min(ns[name]):8.3f})"
    if COUNT:
        a = [counted(case, reps, arg) for _ in range(3)]
        b = [counted(case, 2 * reps, arg) for _ in range(3)]
        n = reps * units[name]
        ins = (statistics.median(x[0] for x in b) - statistics.median(x[0] for x in a)) / n
        cyc = (statistics.median(x[1] for x in b) - statistics.median(x[1] for x in a)) / n
        line += f"  ins {ins:7.2f}  cyc {cyc:6.2f}  ipc {ins / cyc:5.2f}"
    print(line, flush=True)
