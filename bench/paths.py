"""paths.py: the path lanes of stury, the best round of each arm's median as ns and as GB/s of the whole text. A lane that
stops early leaves bytes unread, so its ns is what counts.

Usage: python3 bench/paths.py [--rounds N]
A `get` lane reads one root key early, in the middle, late and absent: next's scan, stopped scan and query, and sonic-rs `get` and
simdjson On-Demand `find_field` when their binaries are present. A `logs` lane has next's two arms. Arms that read one
lane must agree on its checksum over the answers' bytes. Rounds interleave the arms.
"""
import fcntl, json, os, sys

from doc import BUILD, LOCK, path as fixture, run

PROBE = os.path.join(BUILD, "paths")
SIMD = os.path.join(BUILD, "cpp_bench")
SONIC = os.path.join(BUILD, "rust", "release", "read")


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


def race(label, size, arms, rounds):
    best = dict.fromkeys(arms, 0.0)
    checks = {}
    for _ in range(rounds):
        for arm, cmdline in arms.items():
            gb, checks[arm], _ = run(cmdline)
            best[arm] = max(best[arm], gb)
    if len(set(checks.values())) > 1:
        sys.exit(f"checksums disagree on {label}: {checks}")
    print(f"{label:22} " + "  ".join(f"{a} {size / b:12.0f} ns {b:8.2f}" for a, b in best.items()), flush=True)


def main(argv):
    rounds = int(os.environ.get("ROUNDS") or 5)
    if argv[:1] == ["--rounds"]:
        rounds = int(argv[1])
    if not os.path.exists(PROBE):
        sys.exit(f"missing {PROBE}: run make bench-paths")
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        for label, path, key in get_lanes():
            arms = {a: [PROBE, a, "." + key, path] for a in ("scan", "stop", "query")}
            if os.path.exists(SONIC):
                arms["sonic"] = [SONIC, "sonic", "sonic_get", path, key]
            if os.path.exists(SIMD):
                arms["simd"] = [SIMD, path, "simd_get", key]
            race(label, os.path.getsize(path), arms, rounds)
        logs = fixture("logs.json")
        for label, paths in LOG_LANES:
            race(label, os.path.getsize(logs), {a: [PROBE, a, paths, logs] for a in ("scan", "query")}, rounds)


if __name__ == "__main__":
    main(sys.argv[1:])
