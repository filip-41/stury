"""Times every case of the kernel bench: wall time per unit over interleaved rounds, then instructions and cycles per
unit from the difference between R and 2R reps, which cancels the setup. Given several binaries, each round runs
every case on each of them in turn, so that they share the machine's drift.

Usage: python3 -I run.py <bench binary>... Every child runs under an RSS cap.
Env: ROUNDS=<n> (default 7), CASES=<regex> keeps the cases whose name matches, COUNT=0 skips the counted pass (no
perf counters).
Counts come from `/usr/bin/time -l` on macOS and `perf stat` on Linux."""
import os, re, statistics, subprocess, sys, time

CAP_MB = 512
BINS = sys.argv[1:]
ROUNDS = int(os.environ.get("ROUNDS") or 7)
COUNT = os.environ.get("COUNT", "1") != "0"
KEEP = re.compile(os.environ.get("CASES", "."))
LINUX = sys.platform.startswith("linux")

# (name, case, reps, arg)
CASES = [("pack 16/256", "pack", 20000, 16), ("json 16/256", "json", 20000, 16), ("csv 16/256", "csv", 20000, 16)]
CASES += [("str none", "str", 20000, 1 << 30), ("str 1/4096", "str", 20000, 4096), ("str 1/64", "str", 20000, 64)]
CASES += [("utf8 none", "utf8", 20000, 1 << 30)] + [(f"utf8 1/{every}", "utf8", 20000, every) for every in (4096, 256, 16)]
CASES += [("utf8all 1/256", "utf8all", 20000, 256)]
CASES += [(f"skip 1/{every}", "skip", 2048, every) for every in (256, 1024, 4096)]
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


def timed(exe, case, reps, arg):
    out, _ = run_capped([exe, case, str(reps), str(arg)])
    sink, ns, units = re.search(r"sink=(\d+) ns=([\d.]+) units=(\d+)", out).groups()
    return int(sink), float(ns), int(units)


def counted(exe, case, reps, arg):
    prefix = ["perf", "stat", "-x,", "-e", "instructions,cycles"] if LINUX else ["/usr/bin/time", "-l"]
    _, err = run_capped(prefix + [exe, case, str(reps), str(arg)])
    if LINUX:
        get = lambda key: int(re.search(r"^(\d+),[^,]*," + key, err, re.M).group(1))
        return get("instructions"), get("cycles")
    get = lambda key: int(re.search(r"(\d+)\s+" + key, err).group(1))
    return get("instructions retired"), get("cycles elapsed")


ns = {(exe, c[0]): [] for exe in BINS for c in CASES}
units = {}
for _ in range(ROUNDS):
    for name, case, reps, arg in CASES:
        for exe in BINS:
            _, t, units[name] = timed(exe, case, reps, arg)
            ns[exe, name].append(t)

for name, case, reps, arg in CASES:
    for exe in BINS:
        label = f"{name:13} {os.path.basename(exe) if len(BINS) > 1 else ''}"
        line = f"{label:30} ns {statistics.median(ns[exe, name]):8.3f} (best {min(ns[exe, name]):8.3f})"
        if COUNT:
            a = [counted(exe, case, reps, arg) for _ in range(3)]
            b = [counted(exe, case, 2 * reps, arg) for _ in range(3)]
            n = reps * units[name]
            ins = (statistics.median(x[0] for x in b) - statistics.median(x[0] for x in a)) / n
            cyc = (statistics.median(x[1] for x in b) - statistics.median(x[1] for x in a)) / n
            line += f"  ins {ins:7.2f}  cyc {cyc:6.2f}  ipc {ins / cyc:5.2f}"
        print(line, flush=True)
