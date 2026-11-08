"""typed.py: the typed read's lanes, median GB/s with strings borrowed and copied, beside serde_json's and sonic-rs's
derived readers into the same structs. The best round of each arm's median counts.

Usage: python3 bench/typed.py [--rounds N] [LANE...]
LANE is one of logs, twitter, citm, table and text, each bound to the struct its probe reads, so no other file is
read. `ARMS=stury,serde` keeps a subset.
Arms: stury (the probe `build/bench/typed`, on an arena), and serde and sonic when `build/bench/rust/release/typed` is
present, on the JSON lanes. A copied string is a `String` in the Rust arms and a borrowed one a `Text`, borrowed from
the input when it has no escape, as stury borrows it. Every arm of a lane prints `check=`, a fold of the value it read,
and no lane is timed before they agree. Rounds interleave the arms, and the runner holds build/bench/timing.lock.
"""
import os, sys

from guard import BUILD, locked
from doc import parse_args, path as fixture, preamble, run, select_arms

PROBE = os.path.join(BUILD, "typed")
RUST = os.path.join(BUILD, "rust", "release", "typed")
LANES = [("logs", "logs.json"), ("twitter", "twitter.json"), ("citm", "citm_catalog.json"), ("table", "table.csv"), ("text", "text.csv")]
MODES = ["borrow", "copy"]


def command(arm, lane, mode, path):
    """The arm's command line, or None where the arm reads no such lane."""
    if arm == "stury":
        return [PROBE, lane, mode, path]
    if path.endswith(".json") and os.path.exists(RUST):
        return [RUST, arm, lane, mode, path]
    return None


def main(argv):
    rounds, wanted = parse_args(argv, "python3 bench/typed.py [--rounds N] [LANE...]")
    unknown = [w for w in wanted if w not in dict(LANES)]
    if unknown:
        sys.exit(f"no lane {' '.join(unknown)}: the lanes are {' '.join(dict(LANES))}")
    arms = select_arms({"stury": PROBE, "serde": RUST, "sonic": RUST}, "bench-typed")
    if "stury" not in arms:
        sys.exit("the stury arm is not running: run make bench-typed, and leave stury in ARMS")
    preamble(rounds, "GB/s is the source's bytes over time: the best of {rounds} rounds of each arm's median of "
             "ten calls after two warm-ups.")
    with locked():
        print(f"{'lane':<9}{'strings':<9}" + "".join(f"{a:>8}" for a in arms))
        for lane, name in LANES:
            if wanted and lane not in wanted:
                continue
            path = fixture(name)
            for mode in MODES:
                cmds = {a: c for a in arms if (c := command(a, lane, mode, path))}
                checks = {a: run(c)[1] for a, c in cmds.items()}
                if len(set(checks.values())) > 1:
                    sys.exit(f"values disagree on {lane} {mode}: {checks}")
                best = dict.fromkeys(cmds, 0.0)
                for _ in range(rounds):
                    for arm, c in cmds.items():
                        best[arm] = max(best[arm], run(c)[0])
                print(f"{lane:<9}{mode:<9}" + "".join(f"{best[a]:8.2f}" if a in best else f"{'-':>8}" for a in arms), flush=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
