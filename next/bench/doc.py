"""doc.py: the document lanes of next/ against the other parsers, GB/s as the best round of each arm's median
and peak RSS as the median of the rounds' kernel-tracked child maxima.

Usage: python3 next/bench/doc.py [--rounds N] [FILE...]
Arms: `next` (next/bench/doc), and yy, simd and sonic when their binary is present under next/build/bench.
A fixture that is not plain `.json` runs only `next`, since the other parsers read plain JSON.
Every arm's `check=` must agree before a fixture is timed. Rounds interleave the arms. The runner holds
next/build/bench/timing.lock, kills a child over 1 GB of live RSS, and reports each child's peak RSS from wait4.
"""
import fcntl, os, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
BUILD = os.path.normpath(os.path.join(HERE, "..", "build", "bench"))
LOCK = os.path.join(BUILD, "timing.lock")
CAP_KB = 1024 * 1024
LANES = ("build", "read", "key")

PROBE = os.path.join(BUILD, "doc")
ARMS = ["next", "yy", "simd", "sonic"]
BIN = {
    "next": PROBE,
    "yy": os.path.join(BUILD, "yy_bench"),
    "simd": os.path.join(BUILD, "cpp_bench"),
    "sonic": os.path.join(BUILD, "rust", "release", "read"),
}
# The lane's name in each driver's arguments.
LANE_ARG = {
    "next": {"build": ["build"], "read": ["read"], "key": ["key"]},
    "yy": {"build": ["dom"], "read": ["dom_read"], "key": ["key"]},
    "simd": {"build": ["simd_dom"], "read": ["simd_dom_read"], "key": ["simd_key"]},
    "sonic": {"build": ["sonic", "dom"], "read": ["sonic", "sonic_dom_read"], "key": ["sonic", "sonic_key"]},
}


def path(name):
    for d in (FIX, os.path.join(FIX, "corpus")):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    if os.path.exists(name):
        return os.path.abspath(name)
    sys.exit(f"no fixture {name}")


def is_json(name):
    """The peers read plain JSON, not the jsonc and json5 specs."""
    return name.endswith(".json")


def cmd(arm, lane, fixture):
    args = LANE_ARG[arm][lane]
    if arm == "next":
        return [BIN[arm], *args, fixture]
    if arm == "simd":
        return [BIN[arm], fixture, *args]
    return [BIN[arm], *args, fixture]


def peak_mib(ru_maxrss):
    """Converts wait4's maximum RSS to MiB: bytes on macOS, KiB elsewhere."""
    peak_bytes = ru_maxrss if sys.platform == "darwin" else ru_maxrss * 1024
    return peak_bytes / (1024 * 1024)


def run(cmdline):
    """Runs one arm once under the RSS cap and returns (gb_per_s, check, peak MiB) or exits."""
    p = subprocess.Popen(cmdline, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=HERE)
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
            sys.exit(f"over the memory cap: {cmdline}")
        time.sleep(0.005)
    # wait4 reaped the child, so Popen must not wait again; its pipes still hold the output.
    p.returncode = os.waitstatus_to_exitcode(status)
    out, err = p.communicate()
    if p.returncode != 0:
        sys.exit(f"failed {cmdline}: {err.strip()}")
    g = re.search(r"gb_per_s=([\d.]+)", out)
    c = re.search(r"check=(\d+)", out)
    if not g or not c:
        sys.exit(f"no gb_per_s or check from {cmdline}: {out.strip()}")
    return float(g.group(1)), int(c.group(1)), peak_mib(usage.ru_maxrss)


def arms_for(name):
    return [a for a in ARMS if a == "next" or is_json(name)]


def main(argv):
    rounds = int(os.environ.get("ROUNDS") or 5)
    if argv[:1] == ["--rounds"]:
        if len(argv) < 2:
            sys.exit(__doc__)
        rounds = int(argv[1])
        argv = argv[2:]
    files = argv or ["logs.json", "citm_catalog.json", "table.csv"]

    have = [a for a in ARMS if os.path.exists(BIN[a])]
    if os.environ.get("ARMS"):
        wanted = os.environ["ARMS"].split(",")
        have = [a for a in have if a in wanted]
    missing = [a for a in ARMS if a not in have]
    if "next" not in have:
        sys.exit(f"missing {PROBE}: run make bench-doc")
    print("arms: " + " ".join(have) + ("; left out: " + " ".join(missing) if missing else ""))

    os.makedirs(BUILD, exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)

        # Every arm reads the same values or nothing is timed: one pass per arm and lane, compared first.
        for name in files:
            f = path(name)
            for lane in LANES:
                checks = {}
                for arm in arms_for(name):
                    if arm not in have:
                        continue
                    checks[arm] = run(cmd(arm, lane, f))[1]
                if len(set(checks.values())) > 1:
                    shown = " ".join(f"{a}={c}" for a, c in checks.items())
                    sys.exit(f"checksums disagree on {name} {lane}: {shown}")
                print(f"check {name:22} {lane:5} " + " ".join(f"{a}={c}" for a, c in checks.items()), flush=True)

        for lane in LANES:
            best = {name: dict.fromkeys(ARMS, 0.0) for name in files}
            peaks = {name: {a: [] for a in ARMS} for name in files}
            for name in files:
                f = path(name)
                for _ in range(rounds):
                    for arm in arms_for(name):
                        if arm not in have:
                            continue
                        gb, _, mib = run(cmd(arm, lane, f))
                        best[name][arm] = max(best[name][arm], gb)
                        peaks[name][arm].append(mib)

            print(f"\n{lane} GB/s")
            print(f"{'file':22}" + "".join(f"{a:>10}" for a in ARMS))
            for name in files:
                applicable = [a for a in arms_for(name) if a in have]
                print(
                    f"{name:22}"
                    + "".join(
                        f"{best[name][a]:10.3f}" if a in applicable else f"{'-':>10}" for a in ARMS
                    ),
                    flush=True,
                )

            print(f"\n{lane} RSS MiB")
            print(f"{'file':22}" + "".join(f"{a:>10}" for a in ARMS))
            for name in files:
                applicable = [a for a in arms_for(name) if a in have]
                print(
                    f"{name:22}"
                    + "".join(
                        f"{statistics.median(peaks[name][a]):10.2f}" if a in applicable else f"{'-':>10}"
                        for a in ARMS
                    ),
                    flush=True,
                )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
