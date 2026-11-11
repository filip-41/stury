"""doc.py: the document lanes of stury against the other parsers, GB/s as the best round of each arm's median
and peak RSS as the median of the rounds' kernel-tracked child maxima.

Usage: python3 bench/doc.py [--rounds N] [FILE...]
FILE is any fixture the probe reads (JSON, JSONC, JSON5, CSV or TSV), by name or path. The other runners take the
shared `--rounds N` and refuse any other option.
Arms: `stury` (bench/doc), and yy, simd and sonic when their binary is present under build/bench. `ARMS=stury,yy` keeps
a subset.
A fixture that is not plain `.json` runs only `stury`, since the other parsers read plain JSON.
Every arm's `check=` must agree before a fixture is timed. Rounds interleave the arms. The runner holds
build/bench/timing.lock, kills a child over 1 GB of live RSS, and reports each child's peak RSS from wait4.
"""
import os, re, statistics, subprocess, sys, time

from guard import BUILD, locked, over_cap

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
LANES = ("build", "read", "key")

PROBE = os.path.join(BUILD, "doc")
ARMS = ["stury", "yy", "simd", "sonic"]
BIN = {
    "stury": PROBE,
    "yy": os.path.join(BUILD, "yy_bench"),
    "simd": os.path.join(BUILD, "cpp_bench"),
    "sonic": os.path.join(BUILD, "rust", "release", "read"),
}
# The lane's name in each driver's arguments.
LANE_ARG = {
    "stury": {"build": ["build"], "read": ["read"], "key": ["key"]},
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
    sys.exit(f"no fixture {name}: looked in bench/fixtures and bench/fixtures/corpus, and for a file of that path. "
             "make fixtures fetches the corpus and generates the rest")


def rounds_of(text):
    try:
        rounds = int(text)
    except ValueError:
        rounds = 0
    if rounds < 1:
        sys.exit(f"rounds must be a whole number of at least 1, not {text!r}")
    return rounds


def parse_args(argv, usage):
    """The arguments every runner shares: `--rounds N` (default $ROUNDS, else 5) and positional names. Any other option
    is refused with the usage line."""
    rounds, names = rounds_of(os.environ.get("ROUNDS") or "5"), []
    args = iter(argv)
    for arg in args:
        if arg in ("-h", "--help"):
            print("usage: " + usage)
            sys.exit(0)
        if arg == "--rounds":
            rounds = rounds_of(next(args, ""))
        elif arg.startswith("-"):
            sys.exit(f"unknown option {arg}\nusage: {usage}")
        else:
            names.append(arg)
    return rounds, names


def select_arms(binaries, own_target):
    """Prints the arms that run and, for each one left out, why and what to run. `binaries` maps arm to its binary in
    order, `ARMS` keeps a subset, and the stury arm is built by `make OWN_TARGET`. Returns the arms to run."""
    wanted = os.environ.get("ARMS")
    named = wanted.split(",") if wanted else list(binaries)
    unknown = [a for a in named if a not in binaries]
    if unknown:
        sys.exit(f"ARMS names {', '.join(unknown)}, which is not an arm here. The arms are: {' '.join(binaries)}")
    have, left = [], []
    for arm, binary in binaries.items():
        if arm not in named:
            left.append(f"{arm} (not in ARMS)")
        elif not os.path.exists(binary):
            fix = f"make {own_target}" if arm == "stury" else "make fixtures, then make bench-peers"
            left.append(f"{arm} ({os.path.relpath(binary)} is missing: run {fix})")
        else:
            have.append(arm)
    print("arms: " + " ".join(have))
    for arm in left:
        print("left out: " + arm)
    return have


def machine():
    """The Odin version, the CPU and the date, on one line."""
    try:
        out = subprocess.run([os.environ.get("ODIN", "odin"), "version"], capture_output=True, text=True).stdout
    except OSError:
        out = ""
    odin = out.split()[-1] if out.split() else ""
    if sys.platform == "darwin":
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    else:
        cpu = next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), "")
    return f"odin {odin or 'not found, set ODIN'}, {cpu or 'cpu unknown'}, {time.strftime('%Y-%m-%d')}"


def preamble(rounds, legend):
    """The machine line, then LEGEND, which says what the figures are."""
    print(machine())
    print(legend.format(rounds=rounds))


def is_json(name):
    """The peers read plain JSON, not the jsonc and json5 specs."""
    return name.endswith(".json")


def cmd(arm, lane, fixture):
    args = LANE_ARG[arm][lane]
    if arm == "simd":
        return [BIN[arm], fixture, *args]
    return [BIN[arm], *args, fixture]


def peak_mib(ru_maxrss):
    """Converts wait4's maximum RSS to MiB: bytes on macOS, KiB elsewhere."""
    peak_bytes = ru_maxrss if sys.platform == "darwin" else ru_maxrss * 1024
    return peak_bytes / (1024 * 1024)


class Failed(Exception):
    """A child that exited non-zero, passed the memory cap, or ran past its time limit."""


def spawn(cmdline, env=None, timeout=None):
    """Runs one command under the RSS cap and returns (stdout, stderr, rusage), or raises Failed with why."""
    p = subprocess.Popen(cmdline, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=HERE,
                         env={**os.environ, **(env or {})})
    start = time.monotonic()
    while True:
        pid, status, usage = os.wait4(p.pid, os.WNOHANG)
        if pid == p.pid:
            break
        why = "over the memory cap" if over_cap(p.pid) else f"over {timeout} s" if timeout and time.monotonic() - start > timeout else ""
        if why:
            p.kill()
            os.wait4(p.pid, 0)
            p.communicate()
            raise Failed(why)
        time.sleep(0.005)
    # wait4 reaped the child, so Popen must not wait again; its pipes still hold the output.
    p.returncode = os.waitstatus_to_exitcode(status)
    out, err = p.communicate()
    if p.returncode != 0:
        raise Failed((err.strip().splitlines() or ["exit %d" % p.returncode])[-1][:100])
    return out, err, usage


def run(cmdline):
    """Runs one arm once under the RSS cap and returns (gb_per_s, check, peak MiB, ns) or exits. ns is the arm's
    median nanoseconds, None from an arm that prints none."""
    try:
        out, _, usage = spawn(cmdline)
    except Failed as e:
        sys.exit(f"failed {cmdline}: {e}")
    g = re.search(r"gb_per_s=([\d.]+)", out)
    c = re.search(r"check=(\d+)", out)
    if not g or not c:
        sys.exit(f"no gb_per_s or check from {cmdline}: {out.strip()}")
    t = re.search(r"\bns=(\d+)", out)
    return float(g.group(1)), int(c.group(1)), peak_mib(usage.ru_maxrss), int(t.group(1)) if t else None


def arms_for(name):
    return [a for a in ARMS if a == "stury" or is_json(name)]


def main(argv):
    rounds, files = parse_args(argv, "python3 bench/doc.py [--rounds N] [FILE...]")
    files = files or ["logs.json", "citm_catalog.json", "table.csv", "logs.jsonc", "logs.json5"]
    have = select_arms(BIN, "bench-doc")
    if "stury" not in have:
        sys.exit("the stury arm is not running: run make bench-doc, and leave stury in ARMS")
    preamble(rounds, "GB/s is the source's bytes over time: the best of {rounds} rounds of each arm's median of ten calls after two warm-ups. "
             "RSS is the median over the rounds of the child's peak.")

    with locked():

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
                        gb, _, mib, _ = run(cmd(arm, lane, f))
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
