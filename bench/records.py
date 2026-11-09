"""records.py: the record lanes of stury on the NDJSON and CSV fixtures, and the other libraries' record readers on the
same files, GB/s as the best round of each arm's median.

Usage: python3 bench/records.py [--rounds N] [FIXTURE...]
FIXTURE is one of the fixtures in `FIXTURES`, each with the lanes its type allows. Tables show the fixtures given.
Arms: the lanes of the probe `build/bench/records`, and the peers present under build/bench:
  simd, simd_nt   simdjson's parse_many (a tape per document) over the NDJSON text, with its stage 1 threaded (the
                  default) and with `threaded = false`
  simd_od, simd_od_nt   simdjson's On-Demand iterate_many, each document skipped, threaded and not. It judges the
                  structure and not the escapes or number syntax of what it skips
  serde_validate, serde_value   serde_json's StreamDeserializer to IgnoredAny and to a Value
  sonic_validate, sonic_value   sonic-rs's StreamDeserializer to IgnoredAny and to a Value
  csv_frame       simd-csv's Splitter, each record's bytes and no cells
Every arm of a fixture prints the number of records it passed as `check=`, and no fixture is timed before they agree.
Rounds interleave the arms, and the runner holds build/bench/timing.lock.
"""
import os, sys

from guard import BUILD, locked
from doc import parse_args, path as fixture, preamble, run, select_arms

PROBE = os.path.join(BUILD, "records")
SIMD = os.path.join(BUILD, "cpp_bench")
RUST = os.path.join(BUILD, "rust", "release", "records")

NDJSON = ["logs.ndjson", "docs.ndjson", "twitter.ndjson"]
CSV = ["table.csv", "text.csv", "wide.csv"]
FIXTURES = NDJSON + ["logs.json"] + CSV
LANES = ["frame", "check", "build", "stream", "read", "refuse", "write", "cells", "rows", "text"]
# The probe's lanes that run on a pool of 6 threads.
POOLED = ["threads", "validate", "each"]

# The peers' command lines, `{}` the fixture's path.
PEERS = {
    "simd": [SIMD, "{}", "simd_stream"],
    "simd_nt": [SIMD, "{}", "simd_stream_nothread"],
    "simd_od": [SIMD, "{}", "simd_stream_skip"],
    "simd_od_nt": [SIMD, "{}", "simd_stream_skip_nothread"],
    "serde_validate": [RUST, "serde", "validate", "{}"],
    "serde_value": [RUST, "serde", "value", "{}"],
    "sonic_validate": [RUST, "sonic", "validate", "{}"],
    "sonic_value": [RUST, "sonic", "value", "{}"],
    "csv_frame": [RUST, "csv", "frame", "{}"],
}
# The tables: a title, the fixtures, and the arms of each column, the probe's lanes among the peers' where the job is
# the same. Every arm of a table runs on one thread, or every arm of it on more than one.
TABLES = [
    ("lanes, one thread", FIXTURES, LANES),
    ("lanes, 6 threads", FIXTURES, POOLED),
    ("check, NDJSON, one thread", NDJSON, ["check", "simd_nt", "simd_od_nt", "serde_validate", "sonic_validate"]),
    ("check, NDJSON, threaded", NDJSON, ["threads", "simd", "simd_od"]),
    ("document per record, NDJSON", NDJSON, ["build", "serde_value", "sonic_value"]),
    ("frame, CSV", ["table.csv", "text.csv"], ["frame", "csv_frame"]),
]


# The lanes that read a record into a type or write a list of them know the fixture's type.
EXTRA_LANES = {
    "logs.ndjson": ["build", "stream", "read", "refuse", "write"],
    "docs.ndjson": ["build", "stream"],
    "twitter.ndjson": ["build", "stream"],
    "table.csv": ["cells", "rows", "write"],
    "text.csv": ["cells", "text", "write"],
    "wide.csv": ["cells"],
}


def lanes_of(name):
    """The probe's lanes that run on the fixture."""
    if name == "logs.json":
        return ["validate", "each"]
    # `validate` judges a whole text as one document, which an NDJSON text is not.
    return ["frame", "check", "threads", "each"] + ["validate"] * name.endswith(".csv") + EXTRA_LANES[name]


def peers_of(name):
    """The peers that read the fixture: the JSON ones the NDJSON text, simd-csv the two CSV texts with cells to frame."""
    if name in NDJSON:
        return [p for p in PEERS if p != "csv_frame"]
    return ["csv_frame"] if name in ("table.csv", "text.csv") else []


def command(arm, name):
    if arm in PEERS:
        return [fixture(name) if a == "{}" else a for a in PEERS[arm]]
    return [PROBE, arm, fixture(name)]


def main(argv):
    rounds, wanted = parse_args(argv, "python3 bench/records.py [--rounds N] [FIXTURE...]")
    unknown = [w for w in wanted if w not in FIXTURES]
    if unknown:
        sys.exit(f"no fixture {' '.join(unknown)}: the fixtures are {' '.join(FIXTURES)}")
    fixtures = wanted or FIXTURES
    have = select_arms({"stury": PROBE, "simdjson": SIMD, "rust": RUST}, "bench-records")
    if "stury" not in have:
        sys.exit("the stury arm is not running: run make bench-records, and leave stury in ARMS")
    absent = {p for p in PEERS if ("simdjson" if PEERS[p][0] == SIMD else "rust") not in have}
    preamble(rounds, "GB/s is the source's bytes over time (the bytes written, in the write lane): the best of {rounds} "
             "rounds of each arm's median of ten calls after two warm-ups.")
    with locked():
        best = {}
        for name in fixtures:
            arms = lanes_of(name) + [p for p in peers_of(name) if p not in absent]
            # Every arm passes the same records, or nothing is timed. logs.json has none to compare: `validate` reads
            # it as one document and `each` as the entries of its spine.
            if name != "logs.json":
                counts = {arm: run(command(arm, name))[1] for arm in arms}
                if len(set(counts.values())) > 1:
                    sys.exit(f"record counts disagree on {name}: {counts}")
                print(f"check {name:16} {next(iter(counts.values()))} records", flush=True)
            best[name] = dict.fromkeys(arms, 0.0)
            for _ in range(rounds):
                for arm in arms:
                    best[name][arm] = max(best[name][arm], run(command(arm, name))[0])
        for title, names, columns in TABLES:
            shown = [c for c in columns if any(c in best[n] for n in names if n in best)]
            if not shown:
                continue
            print(f"\n{title} GB/s")
            print(f"{'fixture':16}" + "".join(f"{c:>15}" for c in shown))
            for name in [n for n in names if n in best]:
                print(f"{name:16}" + "".join(f"{best[name][c]:15.2f}" if c in best[name] else f"{'':>15}" for c in shown))
        print("\nThreaded: stury's `threads` on 6 threads, simd and simd_od with stage 1 in a thread of its own.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
