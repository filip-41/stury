"""typed.py: the typed read's lanes, median GB/s on an arena, strings borrowed and copied, beside the old tree where a
checkout holds it. Each round runs the arms in turn, and the best round of each arm's median counts. The old arm is
built by compare/typed_oracle/build.sh, each string mode a program of its own.

Usage: ODIN=odin ROUNDS=5 python3 next/bench/typed.py
"""
import fcntl, os, subprocess, sys

from doc import BUILD, LOCK, path as fixture

HERE = os.path.dirname(os.path.abspath(__file__))
BUILDER = os.path.join(HERE, "..", "..", "compare", "typed_oracle", "build.sh")
LANES = [("logs", "logs.json"), ("twitter", "twitter.json"), ("citm", "citm_catalog.json"), ("table", "table.csv"), ("text", "text.csv")]
MODES = [("borrow", "true"), ("copy", "false")]
ITERS = 41


def rate(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.split()
    return float(out[1])


def old_arms():
    """The old probe of each string mode, or an empty map where this checkout has no old tree."""
    arms = {}
    if not os.path.exists(BUILDER):
        return arms
    for mode, borrow in MODES:
        out = os.path.join(BUILD, "typed_old_" + mode)
        env = dict(os.environ, BORROW=borrow)
        if subprocess.run(["bash", BUILDER, out], env=env, capture_output=True).returncode == 0:
            arms[mode] = os.path.join(out, "old")
    return arms


def main():
    rounds = int(os.environ.get("ROUNDS", "5"))
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = old_arms()
        probe = os.path.join(BUILD, "typed")
        print(f"{'lane':<9}{'strings':<9}{'old':>8}{'next':>8}{'delta':>8}")
        for lane, name in LANES:
            path = fixture(name)
            for mode, _ in MODES:
                best_new = best_old = 0.0
                for _ in range(rounds):
                    if mode in old:
                        best_old = max(best_old, rate([old[mode], "time", lane, path, str(ITERS)]))
                    best_new = max(best_new, rate([probe, lane, mode, path, str(ITERS)]))
                delta = f"{(best_new / best_old - 1) * 100:+.1f}%" if best_old else "-"
                print(f"{lane:<9}{mode:<9}{best_old:>8.2f}{best_new:>8.2f}{delta:>8}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
