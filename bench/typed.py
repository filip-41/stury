"""typed.py: the typed read's lanes, median GB/s on an arena, strings borrowed and copied. The best round of each
lane's median counts.

Usage: ROUNDS=5 python3 bench/typed.py
"""
import fcntl, os, subprocess, sys

from doc import BUILD, LOCK, path as fixture

LANES = [("logs", "logs.json"), ("twitter", "twitter.json"), ("citm", "citm_catalog.json"), ("table", "table.csv"), ("text", "text.csv")]
MODES = ["borrow", "copy"]
ITERS = 41


def rate(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.split()
    return float(out[1])


def main():
    rounds = int(os.environ.get("ROUNDS", "5"))
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        probe = os.path.join(BUILD, "typed")
        print(f"{'lane':<9}{'strings':<9}{'GB/s':>8}")
        for lane, name in LANES:
            path = fixture(name)
            for mode in MODES:
                best = max(rate([probe, lane, mode, path, str(ITERS)]) for _ in range(rounds))
                print(f"{lane:<9}{mode:<9}{best:>8.2f}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
