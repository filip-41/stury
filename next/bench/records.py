"""records.py: the record reader's lanes on the NDJSON and CSV fixtures, the best round of each lane's median GB/s.

Usage: ROUNDS=5 python3 next/bench/records.py
"""
import fcntl, os, subprocess, sys

from doc import BUILD, LOCK, path as fixture

FIXTURES = ["logs.ndjson", "docs.ndjson", "twitter.ndjson", "table.csv", "text.csv", "wide.csv"]
LANES = ["frame", "check", "read", "cells", "rows"]
ITERS = 41


def main():
    rounds = int(os.environ.get("ROUNDS", "5"))
    probe = os.path.join(BUILD, "records")
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print(f"{'fixture':<16}" + "".join(f"{lane:>8}" for lane in LANES))
        for name in FIXTURES:
            path = fixture(name)
            # `read` and `rows` read into the struct of the logs records and the table rows alone.
            if name.endswith(".csv"):
                lanes = LANES[3:] if name == "table.csv" else LANES[3:4]
            else:
                lanes = LANES[:3] if name == "logs.ndjson" else LANES[:2]
            best = {lane: 0.0 for lane in LANES}
            for _ in range(rounds):
                for lane in lanes:
                    out = subprocess.run([probe, lane, path, str(ITERS)], capture_output=True, text=True, check=True)
                    best[lane] = max(best[lane], float(out.stdout.split()[1]))
            print(f"{name:<16}" + "".join(f"{best[lane]:>8.2f}" if lane in lanes else f"{'':>8}" for lane in LANES), flush=True)


if __name__ == "__main__":
    sys.exit(main())
