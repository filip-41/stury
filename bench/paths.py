"""paths.py: the path lanes of stury, the best round of each arm's median as ns, and as GB/s of the whole text computed
from it. A lane that stops early leaves bytes unread, so its table shows ns alone.

Usage: python3 bench/paths.py [--rounds N]
The lanes and their fixtures (wide.json, twitter.json, logs.json) are fixed, so it takes no file.
A `get` lane reads one root key early, in the middle, late and absent from the text: stury's scan, stopped scan and a
build then query, and sonic-rs `get` and simdjson On-Demand `find_field` when their binaries are present. A `logs` lane
has stury's scan and a query of a document built outside the clock. Arms that read one lane must agree on its checksum
over the answers' bytes. Rounds interleave the arms.

Each table holds the arms that read the same amount of the text, named in its title:
  scan          judges every byte of the text
  build_query   builds the document, judging every byte, then queries it
  simd          stage 1 over the whole text (its structure and UTF-8), then On-Demand reads to the key and skips values
                without judging their numbers and escapes
  stop          judges every byte up to the answer and leaves the rest unread
  sonic         reads to the key and skips values without judging them, and leaves the rest unread
  query         queries a document built outside the clock, and reads only the nodes the path reaches
"""
import json, os, sys

from guard import BUILD, locked
from doc import parse_args, path as fixture, preamble, run, select_arms

PROBE = os.path.join(BUILD, "paths")
SIMD = os.path.join(BUILD, "cpp_bench")
SONIC = os.path.join(BUILD, "rust", "release", "read")
# Calls per timed sample in a get lane, the same for every arm. One call of the early key takes under a quarter of a
# microsecond, close to the clock's 41.7 ns tick, so a sample is a batch whose time is divided by it.
GET_BATCH = 100


def root_keys(path):
    with open(path) as f:
        return list(json.load(f))


def get_lanes():
    """Four keys of the fixture with many root keys, and the last key of one with few."""
    wide = fixture("wide.json")
    keys = root_keys(wide)
    lanes = [("get early", wide, keys[0]), ("get middle", wide, keys[len(keys) // 2]), ("get late", wide, keys[-1]),
             ("get absent", wide, "no_such_key")]
    twitter = fixture("twitter.json")
    lanes.append(("get last root key", twitter, root_keys(twitter)[-1]))
    return lanes


FIELDS = ("ts", "level", "service", "status", "id")
LOG_LANES = [(".logs[].id", ".logs[].id"), (".logs[][]", ".logs[][]"), (".logs[-1]", ".logs[-1]"), (".logs[-20]", ".logs[-20]"),
             ("five keys per record", ";".join(f".logs[].{k}" for k in FIELDS))]


# (title, arms, whether GB/s of the whole text means something: not where the arms stop at the answer)
GET_TABLES = [("get, the whole text read", ["scan", "build_query", "simd"], True),
              ("get, the text read up to the answer", ["stop", "sonic"], False)]
LOG_TABLES = [("logs, the whole text judged", ["scan"], True), ("logs, a document built outside the clock", ["query"], True)]


def race(label, arms, rounds):
    """Each arm's best median ns, once every arm agrees on the answers."""
    best = dict.fromkeys(arms, float("inf"))
    checks = {}
    for _ in range(rounds):
        for arm, cmdline in arms.items():
            _, checks[arm], _, ns = run(cmdline)
            best[arm] = min(best[arm], ns)
    if len(set(checks.values())) > 1:
        sys.exit(f"checksums disagree on {label}: {checks}")
    print(f"check {label:22} " + " ".join(checks), flush=True)
    return best


def show(tables, rows):
    """Prints each table: one row per lane, ns for each of the table's arms the lane ran, and GB/s where the arms read
    the whole text."""
    for title, columns, throughput in tables:
        shown = [c for c in columns if any(c in best for _, _, best in rows)]
        if not shown:
            continue
        print(f"\n{title}")
        print(f"{'lane':22}" + "".join(f"{c + ' ns':>16}" + (f"{'GB/s':>10}" if throughput else "") for c in shown))
        for label, size, best in rows:
            print(f"{label:22}" + "".join(
                (f"{best[c]:16d}" + (f"{size / best[c]:10.2f}" if throughput else "")) if c in best
                else f"{'-':>16}" + (f"{'':>10}" if throughput else "") for c in shown))


def main(argv):
    rounds, files = parse_args(argv, "python3 bench/paths.py [--rounds N]")
    if files:
        sys.exit("bench/paths.py takes no file: its lanes and fixtures are fixed")
    have = select_arms({"stury": PROBE, "sonic": SONIC, "simd": SIMD}, "bench-paths")
    if "stury" not in have:
        sys.exit("the stury arm is not running: run make bench-paths, and leave stury in ARMS")
    preamble(rounds, "ns per call is the best of {rounds} rounds of each arm's median of ten samples after two warm-ups, "
             f"a sample being {GET_BATCH} calls in a get lane and 1 in a logs lane. GB/s is the whole text's bytes over "
             "that ns.")
    with locked():
        rows = []
        for label, path, key in get_lanes():
            arms = {a: [PROBE, a, "." + key, path, str(GET_BATCH)] for a in ("scan", "stop", "build_query")}
            if "sonic" in have:
                arms["sonic"] = [SONIC, "sonic", "sonic_get", path, key, str(GET_BATCH)]
            if "simd" in have:
                arms["simd"] = [SIMD, path, "simd_get", key, str(GET_BATCH)]
            rows.append((label, os.path.getsize(path), race(label, arms, rounds)))
        logs = fixture("logs.json")
        log_rows = [(label, os.path.getsize(logs), race(label, {a: [PROBE, a, paths, logs] for a in ("scan", "query")}, rounds))
                    for label, paths in LOG_LANES]
    show(GET_TABLES, rows)
    show(LOG_TABLES, log_rows)


if __name__ == "__main__":
    main(sys.argv[1:])
